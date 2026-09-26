"""Local, on-box lyrics transcription — the timing half of the lyrics system.

Why this exists alongside lyrics_ai.py
--------------------------------------
lyrics_ai.py asks Gemini to both *read* the words and *say where they sit in
time*. It is good at the first and structurally bad at the second: a language
model has no clock, so it estimates timestamps, and those estimates drift badly
over a track — see the "Windowed transcription" comment block in that module,
which exists entirely to work around the drift by cutting the audio into short
windows so the error cannot accumulate. That workaround costs one model call per
window, and it is still an estimate.

An ASR model does not have this problem. Whisper aligns its output to the audio
it actually heard, so the timestamps are measured rather than guessed, and they
come out per WORD. That makes it both cheaper and more accurate for exactly the
thing Gemini was worst at, which is why this is the preferred path and Gemini is
now the fallback rather than the default.

It is also free of the constraint that shaped the whole feature: no API key, no
quota, no 429, no 503. A hosted model's request allowance is finite and shared
across everyone using a deployment, which is what made a per-track transcription
budget something that had to be reasoned about at all.

Measured on a modest 4-core CPU with no GPU, using `base.en` at int8: roughly
6-15x realtime, i.e. a three-and-a-half minute track in well under a minute,
holding ~200 MB resident. A deployment like that is typically sharing its cores
with other latency-sensitive work, so the model size, thread count and
concurrency below are all deliberately conservative and all env-overridable —
raise them if the host has room.

Same failure contract as lyrics_ai.transcribe_lyrics: returns None on any
failure, and every caller already treats "no AI lyrics for this track" as a
normal outcome.
"""

import asyncio
import logging
import os
import tempfile
import threading
import time

logger = logging.getLogger("ios-bridge.lyrics_whisper")

# `base.en` is the default because it is the smallest model that transcribed a
# real track correctly in testing, and because English is what the lyrics
# database fallbacks (LRCLIB/lyrics.ovh) cover best anyway. Set to `base` or
# `small` for multilingual material — `.en` variants refuse non-English and will
# produce confident nonsense rather than failing, so the multilingual model is
# the right call for a non-English library even though it is slower.
_MODEL_NAME = os.getenv("LUMISOUND_WHISPER_MODEL", "base.en")

# int8 roughly halves both memory and time versus float32 on CPU for a quality
# difference that did not show up in side-by-side transcripts of real audio.
_COMPUTE_TYPE = os.getenv("LUMISOUND_WHISPER_COMPUTE_TYPE", "int8")

# Three, not all four cores. One core is deliberately left for the database and
# whatever else shares the box: a CPU-saturating background job can starve
# latency-sensitive audio work into audible stuttering, and a lyrics transcript
# is never worth that.
_THREADS = int(os.getenv("LUMISOUND_WHISPER_THREADS", "3"))

# Where CTranslate2 model weights are cached. Inside the image's existing cache
# directory so a container restart doesn't re-download ~150 MB.
_DOWNLOAD_ROOT = os.getenv("LUMISOUND_WHISPER_CACHE", "/app/cache/whisper")

# One transcription at a time, process-wide. The model itself is threaded, so two
# concurrent jobs would not be faster — they would just both be slow while
# doubling the memory and the CPU pressure on a box that cannot afford either.
_SEMAPHORE = asyncio.Semaphore(1)

# --- Line grouping -----------------------------------------------------------
#
# Whisper emits segments that are far too coarse for a synced-lyrics display:
# on a real 26-second clip it returned four segments, one of which was three
# sentences long. A karaoke line is a handful of words. So the segments are
# discarded and lines are rebuilt from the WORD timestamps, which is the level
# the timing is actually accurate at.

# A gap this long between two sung words is a phrase boundary. Tuned against
# sung audio rather than speech: singers hold notes and pause between lines far
# more than speakers do, so a speech-tuned threshold (~0.2s) shatters a sung
# line into fragments.
_LINE_GAP_SECONDS = float(os.getenv("LUMISOUND_WHISPER_LINE_GAP", "0.9"))

# Hard ceilings so one unbroken melisma or a missing pause cannot produce a
# single line that fills the whole screen.
_MAX_LINE_CHARS = 52
_MAX_LINE_SECONDS = 9.0

# Whisper writes non-speech audio as a bracketed annotation rather than leaving
# the segment empty — "(soft music)", "[Music]", "♪♪". These are not lyrics, and
# on a verified instrumental test track they were the ONLY output, which is what
# makes them a reliable instrumental signal instead of a nuisance to strip.
_ANNOTATION_PREFIXES = ("(", "[", "*", "♪", "<")
_ANNOTATION_SUFFIXES = (")", "]", "*", "♪", ">")


def _is_annotation(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    return t.startswith(_ANNOTATION_PREFIXES) and t.endswith(_ANNOTATION_SUFFIXES)


_model = None
_model_lock = threading.Lock()


def _load_model():
    """Loads the model once, lazily, and keeps it resident.

    Lazy rather than at import time so that a deployment which never transcribes
    anything does not pay ~150 MB of download and a startup delay for it, and so
    that a missing/broken faster-whisper install degrades to "local transcription
    unavailable, use Gemini" instead of preventing the whole bridge from booting.
    """
    global _model
    if _model is not None:
        return _model
    with _model_lock:
        if _model is not None:
            return _model
        from faster_whisper import WhisperModel  # imported here, see docstring
        started = time.monotonic()
        os.makedirs(_DOWNLOAD_ROOT, exist_ok=True)

        def _build(local_only: bool) -> "WhisperModel":
            return WhisperModel(
                _MODEL_NAME,
                device="cpu",
                compute_type=_COMPUTE_TYPE,
                cpu_threads=_THREADS,
                download_root=_DOWNLOAD_ROOT,
                local_files_only=local_only,
            )

        # Offline first. The weights are baked into the image (see the Dockerfile),
        # but faster-whisper still makes a revision-check call to Hugging Face
        # unless told not to — which would make local transcription quietly
        # dependent on HF being reachable, defeating half the point of moving off
        # a network service. Falls back to a downloading load so that pointing
        # LUMISOUND_WHISPER_MODEL at a model the image doesn't carry still works.
        try:
            _model = _build(True)
        except Exception as exc:
            logger.info(
                "whisper: %s not in the local cache (%s) — fetching it", _MODEL_NAME, exc)
            _model = _build(False)
        logger.info(
            "whisper: loaded %s (%s, %d threads) in %.1fs",
            _MODEL_NAME, _COMPUTE_TYPE, _THREADS, time.monotonic() - started,
        )
        return _model


def is_available() -> bool:
    """Whether local transcription can be attempted at all.

    Deliberately does NOT load the model — this is called on the request path to
    decide which engine to use, and loading takes seconds on a cold cache.
    """
    if os.getenv("LUMISOUND_WHISPER_ENABLED", "1") not in ("1", "true", "yes"):
        return False
    try:
        import faster_whisper  # noqa: F401
    except Exception:
        return False
    return True


def _phrase_text(chunk) -> str:
    return " ".join(" ".join((w.word or "").strip() for w in chunk).split())


def _split_overlong(chunk: list) -> list[list]:
    """Breaks one over-long phrase at its most natural internal seam.

    Needed because the small models punctuate unreliably on sung audio: on a real
    clip `base.en` returned "Wasn't that hard really you didn't leave behind
    anyone you cared about?" as one unpunctuated run, where a bigger model heard
    "Wasn't that hard. Really?". With no sentence boundary to break on, a plain
    character ceiling snaps the line at whatever word happens to cross it —
    which is how "...leave behind anyone / you cared about?" gets split across
    two lines mid-phrase.

    So the break point is chosen rather than stumbled into: a comma is the best
    seam, and failing that the longest pause between two words, which on sung
    material is almost always a real phrase boundary. The character ceiling then
    only decides *whether* to split, never *where*.
    """
    if len(chunk) < 4:
        return [chunk]

    # Only consider seams that leave both halves reasonably sized, so a break
    # never produces a two-word orphan line.
    lo, hi = 1, len(chunk) - 1
    candidates = range(max(1, lo), max(lo + 1, hi))

    best_idx, best_score = None, float("-inf")
    for i in candidates:
        prev_token = (chunk[i - 1].word or "").strip()
        gap = float(chunk[i].start) - float(chunk[i - 1].end)
        # A comma outranks any pause; otherwise the pause length decides. The
        # balance term keeps the split near the middle when several seams tie,
        # which avoids a 2-word line followed by a 10-word one.
        score = gap + (1.0 if prev_token.endswith((",", ";", ":", "—", "-")) else 0.0)
        score -= abs(i - len(chunk) / 2) * 0.01
        if score > best_score:
            best_idx, best_score = i, score

    if best_idx is None:
        return [chunk]
    left, right = chunk[:best_idx], chunk[best_idx:]
    out: list[list] = []
    # Recursive so a very long run (a rapped verse with no punctuation at all)
    # is broken as many times as it needs, not just once.
    for half in (left, right):
        if len(_phrase_text(half)) > _MAX_LINE_CHARS and len(half) >= 4:
            out.extend(_split_overlong(half))
        else:
            out.append(half)
    return out


def _group_words_into_lines(words) -> list[dict]:
    """Rebuilds lyric-sized lines from word timestamps.

    Two passes. First the words are cut into phrases at the boundaries that are
    genuinely meaningful — sentence-ending punctuation, a pause longer than
    `_LINE_GAP_SECONDS`, or a phrase running past `_MAX_LINE_SECONDS`. Only then
    are any still-too-wide phrases subdivided, at their best internal seam (see
    `_split_overlong`). Doing it in that order is what keeps the character limit
    from overriding a real phrase boundary.

    Each line's timestamp is its FIRST word's start — the moment the line should
    appear on screen, which is all a synced-lyrics view needs.
    """
    phrases: list[list] = []
    current: list = []

    for w in words:
        if not (w.word or "").strip():
            continue
        if current:
            gap = float(w.start) - float(current[-1].end)
            span = float(current[-1].end) - float(current[0].start)
            # The pause belongs BEFORE this word, so the phrase is closed first
            # and this word opens the next one — otherwise the gap would be
            # swallowed by the phrase that just ended and the next line would
            # appear late.
            if gap > _LINE_GAP_SECONDS or span >= _MAX_LINE_SECONDS:
                phrases.append(current)
                current = []
        current.append(w)
        if (w.word or "").strip().endswith((".", "?", "!", "…")):
            phrases.append(current)
            current = []
    if current:
        phrases.append(current)

    lines: list[dict] = []
    for phrase in phrases:
        chunks = ([phrase] if len(_phrase_text(phrase)) <= _MAX_LINE_CHARS
                  else _split_overlong(phrase))
        for chunk in chunks:
            text = _phrase_text(chunk)
            if not text or _is_annotation(text):
                continue
            lines.append({
                "time_seconds": round(max(0.0, float(chunk[0].start)), 2),
                "text": text,
            })
    return lines


def _transcribe_sync(path: str, language: str | None) -> dict | None:
    model = _load_model()
    # vad_filter drops silence and non-vocal stretches before the model sees
    # them, which on music both speeds things up and — more importantly — stops
    # Whisper from inventing words over an instrumental passage, its single most
    # common failure on this kind of audio.
    segments, info = model.transcribe(
        path,
        language=language,
        vad_filter=True,
        word_timestamps=True,
        beam_size=5,
        # Whisper's decoder can fall into repeating one phrase forever on
        # music. This makes it give up on such a segment rather than emit a
        # hundred identical lines.
        condition_on_previous_text=False,
    )

    words = []
    annotation_only = True
    any_segment = False
    logprobs: list[float] = []
    for seg in segments:
        any_segment = True
        logprobs.append(seg.avg_logprob)
        if not _is_annotation(seg.text):
            annotation_only = False
        for w in (seg.words or []):
            words.append(w)

    if not any_segment or annotation_only or not words:
        # Nothing sung. Reported as a genuine instrumental rather than as a
        # failure, because that is a real and useful answer for the client — and
        # it is the answer a verified instrumental track actually produced here.
        logger.info("whisper: no vocals detected — reporting instrumental")
        return {"instrumental": True, "confidence": "high", "lines": [],
                "engine": "whisper", "language": getattr(info, "language", None)}

    lines = _group_words_into_lines(words)
    if not lines:
        return None

    # avg_logprob is Whisper's own confidence, roughly -0.1 (certain) to -1.0
    # (guessing). The thresholds are deliberately conservative: a wrong lyric
    # presented confidently is worse than one flagged as uncertain.
    mean_logprob = sum(logprobs) / len(logprobs) if logprobs else -1.0
    if mean_logprob > -0.45:
        confidence = "high"
    elif mean_logprob > -0.75:
        confidence = "medium"
    else:
        confidence = "low"

    return {
        "instrumental": False,
        "confidence": confidence,
        "lines": lines,
        "engine": "whisper",
        "language": getattr(info, "language", None),
        "mean_logprob": round(mean_logprob, 3),
    }


async def transcribe_lyrics_local(
    audio_bytes: bytes,
    mime_type: str,
    title: str,
    artist: str,
    duration_seconds: float | None = None,
) -> dict | None:
    """Local counterpart to lyrics_ai.transcribe_lyrics, same return shape.

    `hint_lyrics` is deliberately NOT a parameter. Gemini can be handed candidate
    text and asked to correct itself against it; an ASR model has no such input —
    it reports what it heard. Re-timing known-correct text against Whisper's
    output is a real thing worth doing, but it is a text-alignment problem rather
    than a transcription one, so it does not belong in here.
    """
    if not is_available():
        return None

    suffix = ".m4a"
    if "mpeg" in mime_type or "mp3" in mime_type:
        suffix = ".mp3"
    elif "wav" in mime_type:
        suffix = ".wav"
    elif "flac" in mime_type:
        suffix = ".flac"

    # Written to disk because the decoder wants a seekable container; an
    # in-memory buffer works for some formats and fails confusingly for others.
    tmp_path = None
    started = time.monotonic()
    try:
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as fh:
            fh.write(audio_bytes)
            tmp_path = fh.name

        language = None if not _MODEL_NAME.endswith(".en") else "en"
        async with _SEMAPHORE:
            result = await asyncio.to_thread(_transcribe_sync, tmp_path, language)

        elapsed = time.monotonic() - started
        if result is None:
            logger.warning("whisper: produced no usable lines for %r (%.1fs)", title, elapsed)
            return None
        speed = f"{duration_seconds / elapsed:.1f}x" if duration_seconds and elapsed > 0 else "n/a"
        logger.info(
            "whisper: %r by %r -> %d line(s), confidence=%s, instrumental=%s in %.1fs (%s realtime)",
            title, artist, len(result.get("lines") or []), result.get("confidence"),
            result.get("instrumental"), elapsed, speed,
        )
        return result
    except Exception:
        logger.exception("whisper: local transcription raised for %r", title)
        return None
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
