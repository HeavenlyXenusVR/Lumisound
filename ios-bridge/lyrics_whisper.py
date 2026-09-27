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

Measured on a modest 4-core CPU with no GPU, using multilingual `base` at int8
against real uploaded tracks: a three-to-four minute song takes roughly 40-70
seconds, holding ~200 MB resident. Earlier versions of this file claimed 6-15x
realtime; that figure came from measuring SPOKEN dialogue with a speech VAD
stripping most of the audio, and it does not describe transcribing actual music,
which is the job. A deployment like this is typically sharing its cores with
other latency-sensitive work, so the model size, thread count and concurrency
below are all deliberately conservative and all env-overridable — raise them if
the host has room.

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

# Multilingual `base`, NOT `base.en`.
#
# Measured on real uploaded tracks rather than assumed. An `.en` model does not
# "produce confident nonsense" on other languages, which is what a comment here
# used to claim — it produces NOTHING: a Japanese track returned zero segments
# from `base.en` and 10 segments / 135 words from multilingual `base`, with the
# language correctly detected at p=0.96. On an English track the two were
# comparable (263 words vs 249) and the multilingual model was actually FASTER
# (41s vs 72s), so there is no English-side cost to trade away.
#
# That matters for any library that is not exclusively English: a track with
# Japanese vocals is the case where `.en` silently returned nothing at all.
_MODEL_NAME = os.getenv("LUMISOUND_WHISPER_MODEL", "base")

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

# --- Instrumental detection ------------------------------------------------
#
# Word density, in words per minute of audio. This is the signal that actually
# separates a sung track from an instrumental one, measured across real uploads:
#
#     a sung track with dense vocals   70.4 words/min
#     a sung track with sparser vocals  34.4 words/min
#     a verified instrumental            2.3 words/min
#
# A ~15x gap with nothing in between, so the threshold sits comfortably clear of
# both sides. What an instrumental produces is not silence but a handful of
# hallucinated words spread over minutes, which is exactly what a density test
# catches and a per-segment test does not.
#
# Explicitly NOT `no_speech_prob`, which was the obvious candidate and does not
# work: it came out at 0.58 and 0.60 on the two vocal tracks against 0.785 on the
# instrumental — far too close to divide on, and high for everything, because sung
# audio over instrumentation does not look like clean speech to the model either.
_INSTRUMENTAL_MAX_WORDS_PER_MIN = float(
    os.getenv("LUMISOUND_WHISPER_INSTRUMENTAL_WPM", "8"))

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
#
# Measured in DISPLAY width, not characters — see `_display_width`. A CJK glyph
# occupies roughly two Latin character cells and carries far more content, so
# counting raw characters let Japanese lines render about twice as wide as the
# English ones they sit beside.
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


# Punctuation that attaches to the word BEFORE it, so no space is inserted.
_CLINGS_LEFT = frozenset(",.!?;:)]}\u2019\u201d%\u2026")
# ...and punctuation that attaches to the word AFTER it.
_CLINGS_RIGHT = frozenset("([{\u2018\u201c$\u00a3\u20ac")


def _display_width(text: str) -> int:
    """Approximate rendered width, counting wide glyphs as two cells.

    Line length is a layout constraint, and `len()` is the wrong measure of it for
    anything but Latin script: a 21-character run of CJK renders about as wide as
    42 Latin ones, so a character-counted ceiling produced CJK lyric lines roughly
    twice the intended width.
    """
    return sum(2 if _is_cjk(ch) else 1 for ch in text)


def _is_cjk(ch: str) -> bool:
    """CJK ideographs, kana, and Hangul — scripts written without spaces."""
    o = ord(ch)
    return (
        0x3040 <= o <= 0x30FF      # hiragana + katakana
        or 0x3400 <= o <= 0x4DBF   # CJK ext A
        or 0x4E00 <= o <= 0x9FFF   # CJK unified
        or 0xF900 <= o <= 0xFAFF   # compatibility ideographs
        or 0xAC00 <= o <= 0xD7AF   # Hangul syllables
        or 0xFF66 <= o <= 0xFF9F   # halfwidth katakana
    )


def _phrase_text(chunk) -> str:
    """Joins word tokens back into a readable line.

    Not a plain `" ".join`, which is what this was and which produced visibly
    broken lyrics on real tracks:
      - CJK came out with a space between every glyph, because Whisper tokenises
        it roughly per character and those scripts are not written with spaces at
        all — space-joining mangles every non-Latin lyric.
      - English punctuation came out detached: "Up to 5 ,000 ,000." because the
        decoder emits "5", ",", "000" as separate tokens.

    So spacing is decided per boundary rather than applied uniformly: omitted
    around CJK, before left-clinging punctuation, and after right-clinging
    punctuation.
    """
    parts = [(w.word or "").strip() for w in chunk]
    parts = [t for t in parts if t]
    if not parts:
        return ""
    out = parts[0]
    for token in parts[1:]:
        prev_char = out[-1]
        next_char = token[0]
        # A comma or period BETWEEN digits is a separator inside one number, not
        # the end of a clause: "5", ",", "000" must rejoin as "5,000". Requires a
        # digit on BOTH sides, so an ordinary pause before a number ("wait, 5
        # more") still gets its space.
        numeric_separator = (
            prev_char in ",."
            and next_char.isdigit()
            and len(out) >= 2
            and out[-2].isdigit()
        )
        need_space = not (
            numeric_separator
            or next_char in _CLINGS_LEFT
            or prev_char in _CLINGS_RIGHT
            # One CJK side is enough: a Latin word next to a CJK one (a band name
            # inside a Japanese lyric) also reads correctly unspaced, which is how
            # it is typeset in practice.
            or _is_cjk(prev_char)
            or _is_cjk(next_char)
        )
        out += (" " if need_space else "") + token
    return " ".join(out.split())


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
        if _display_width(_phrase_text(half)) > _MAX_LINE_CHARS and len(half) >= 4:
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
        chunks = ([phrase] if _display_width(_phrase_text(phrase)) <= _MAX_LINE_CHARS
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


# --- Aligning known-correct lyrics to measured timings -----------------------
#
# The best possible input this feature ever gets is a track where the WORDS are
# already known — fetched from a lyrics database or imported by the user — and
# only the timing is missing. Neither engine alone handles that well: Gemini has
# the words but invents the timing, and Whisper measures the timing but may
# mishear the words. Aligning one against the other takes the good half of each.
#
# The matching is done on a normalised token stream (case and punctuation
# removed) with difflib, which finds the matching blocks between two sequences
# that differ by insertions, deletions and substitutions — exactly the shape of
# the difference between real lyrics and an ASR transcript of them.

_PUNCT_STRIP = str.maketrans("", "", ".,!?;:\"'’‘“”()[]{}-–—…*")

# Below these, the alignment is not trustworthy enough to present as synced.
# A low match rate means the transcript and the candidate text are not really
# the same words — a wrong-language hint, the wrong song's lyrics, or audio too
# noisy to transcribe — and inventing timings for text that was never matched is
# the exact failure this whole module exists to avoid.
_MIN_ALIGNED_LINE_FRACTION = 0.5

# The token ratio is the check that actually discriminates, and the line count
# alone is not enough: feeding an unrelated song's lyrics against a real
# transcript still anchored half the lines, purely on incidental matches of
# common words ("a", "that"), and was accepted. One shared filler word is not
# evidence that a line was heard. Requiring a large share of ALL candidate
# tokens to match makes an unrelated text fail clearly, because unrelated lyrics
# share only function words, while a genuine hint matches most of its content.
_MIN_TOKEN_MATCH_RATIO = 0.45


def _normalise_tokens(text: str) -> list[str]:
    return [t for t in text.lower().translate(_PUNCT_STRIP).split() if t]


def _align_hint_lines(hint_lyrics: str, words) -> list[dict] | None:
    """Times the caller's own lyric lines using Whisper's word timestamps.

    Returns the candidate text unchanged, each line carrying the measured start
    time of its first word that could be matched in the audio, or None when too
    little matched to be believable.
    """
    import difflib

    raw_lines = [ln.strip() for ln in hint_lyrics.splitlines()]
    raw_lines = [ln for ln in raw_lines if ln and not _is_annotation(ln)]
    if not raw_lines:
        return None

    # Flatten the candidate text to a token stream while remembering, for every
    # token, which line it came from — that mapping is what turns a token-level
    # alignment back into per-line timestamps.
    hint_tokens: list[str] = []
    token_line: list[int] = []
    for idx, line in enumerate(raw_lines):
        for tok in _normalise_tokens(line):
            hint_tokens.append(tok)
            token_line.append(idx)
    if not hint_tokens:
        return None

    heard_tokens: list[str] = []
    heard_times: list[float] = []
    for w in words:
        for tok in _normalise_tokens(w.word or ""):
            heard_tokens.append(tok)
            heard_times.append(float(w.start))
    if not heard_tokens:
        return None

    # autojunk=False matters: on long inputs difflib otherwise treats frequent
    # tokens as junk and skips them, and in lyrics the frequent tokens are
    # exactly the ones that repeat across a chorus — the alignment would drop
    # precisely the material it most needs to anchor.
    matcher = difflib.SequenceMatcher(None, hint_tokens, heard_tokens, autojunk=False)

    # Earliest measured time seen for each line, taken from matched tokens only.
    line_time: dict[int, float] = {}
    matched_tokens = 0
    for h_start, a_start, size in matcher.get_matching_blocks():
        matched_tokens += size
        for offset in range(size):
            line_idx = token_line[h_start + offset]
            t = heard_times[a_start + offset]
            if line_idx not in line_time or t < line_time[line_idx]:
                line_time[line_idx] = t

    token_ratio = matched_tokens / len(hint_tokens)
    enough_lines = len(line_time) >= max(1, len(raw_lines) * _MIN_ALIGNED_LINE_FRACTION)
    if token_ratio < _MIN_TOKEN_MATCH_RATIO or not enough_lines:
        logger.info(
            "whisper: candidate text doesn't match the audio well enough to align "
            "(%d/%d lines anchored, %.0f%% of words matched) — transcribing instead",
            len(line_time), len(raw_lines), token_ratio * 100,
        )
        return None

    # Unmatched lines are interpolated between their nearest matched neighbours
    # rather than dropped: a line the model misheard entirely is still a real
    # lyric that belongs on screen, and an evenly-spaced guess between two
    # measured anchors is close enough to read correctly.
    anchors = sorted(line_time)
    out: list[dict] = []
    for idx, line in enumerate(raw_lines):
        if idx in line_time:
            t = line_time[idx]
        else:
            prev = max((a for a in anchors if a < idx), default=None)
            nxt = min((a for a in anchors if a > idx), default=None)
            if prev is None and nxt is None:
                continue
            if prev is None:
                # Before the first anchor: back off from it, without going
                # negative, rather than pinning every leading line to 0.0.
                t = max(0.0, line_time[nxt] - (nxt - idx) * 2.0)
            elif nxt is None:
                t = line_time[prev] + (idx - prev) * 2.0
            else:
                span = line_time[nxt] - line_time[prev]
                t = line_time[prev] + span * ((idx - prev) / (nxt - prev))
        out.append({"time_seconds": round(max(0.0, t), 2), "text": line})

    # Whisper can report a later word as starting fractionally before an earlier
    # one, and interpolation across such a pair would invert two lines. Clamped
    # so the sequence can only ever move forward — a display that jumps backwards
    # is visibly broken in a way a slightly-off timestamp is not.
    last = 0.0
    for entry in out:
        if entry["time_seconds"] < last:
            entry["time_seconds"] = last
        last = entry["time_seconds"]

    logger.info(
        "whisper: aligned %d candidate line(s), %d anchored directly to the audio",
        len(out), len(line_time),
    )
    return out


def _transcribe_sync(path: str, language: str | None,
                     hint_lyrics: str | None = None) -> dict | None:
    model = _load_model()
    # vad_filter is OFF, and turning it on is the single worst thing that can be
    # done to this feature.
    #
    # It was on, with a comment claiming it stopped Whisper inventing words over
    # instrumental passages. Measured against real uploaded tracks, what it
    # actually did was delete the vocals:
    #
    #   sung track A   vad=True:   0 words  ->  vad=False: 148 words
    #   sung track B   vad=True:   4 words  ->  vad=False: 250 words
    #                  (and avg_logprob improved from -1.25 to -0.53)
    #
    # Silero VAD is trained to find SPEECH. Singing over a dense instrumental mix
    # does not look like speech to it, so it strips the very thing being
    # transcribed. Worse, it made the failure invisible: with everything removed,
    # a song full of vocals came back reported as an instrumental — confidently
    # wrong rather than merely empty.
    #
    # The cost of turning it off is real and accepted: a 3-4 minute track now
    # takes 40-70s instead of 2-10s, because it is actually being transcribed
    # rather than mostly skipped. That is what the job/poll design exists for.
    segments, info = model.transcribe(
        path,
        language=language,
        vad_filter=False,
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

    # Instrumental is decided by word DENSITY, not by emptiness.
    #
    # With the VAD gone, an instrumental no longer yields silence — it yields a
    # few hallucinated words scattered over minutes. Measured: 2.3 words/min on a
    # verified instrumental against 34.4 and 70.4 on sung tracks. Emptiness alone
    # would now classify almost nothing, and `no_speech_prob` does not separate
    # these at all (see _INSTRUMENTAL_MAX_WORDS_PER_MIN).
    duration = getattr(info, "duration", None) or 0.0
    words_per_min = (len(words) / (duration / 60.0)) if duration > 0 else None
    sparse = words_per_min is not None and words_per_min < _INSTRUMENTAL_MAX_WORDS_PER_MIN

    if not any_segment or annotation_only or not words or sparse:
        logger.info(
            "whisper: no vocals detected — reporting instrumental (%s words over %.0fs, %s/min)",
            len(words), duration,
            f"{words_per_min:.1f}" if words_per_min is not None else "n/a",
        )
        return {"instrumental": True, "confidence": "high", "lines": [],
                "engine": "whisper", "language": getattr(info, "language", None)}

    # Candidate text present: the words are already known and correct (fetched
    # from a lyrics database or imported by the user), so re-deriving them from
    # what the model thought it heard would be strictly worse. Only the TIMING
    # is missing, and that is what the audio can supply — see _align_hint_lines.
    aligned = None
    if hint_lyrics:
        aligned = _align_hint_lines(hint_lyrics, words)

    lines = aligned if aligned else _group_words_into_lines(words)
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
        "engine": "whisper-aligned" if aligned else "whisper",
        "language": getattr(info, "language", None),
        "mean_logprob": round(mean_logprob, 3),
    }


async def transcribe_lyrics_local(
    audio_bytes: bytes,
    mime_type: str,
    title: str,
    artist: str,
    duration_seconds: float | None = None,
    hint_lyrics: str | None = None,
) -> dict | None:
    """Local counterpart to lyrics_ai.transcribe_lyrics, same return shape.

    When `hint_lyrics` is supplied the words are taken as given and only timed
    against the audio (see `_align_hint_lines`) — that path returns the caller's
    own text verbatim with measured timestamps, which is strictly better than
    either engine alone: the words are already known to be right, and the timing
    is measured rather than estimated. If too little of that text can be matched
    to what was actually heard, alignment is abandoned and the ordinary
    transcription is returned instead, so a mismatched hint degrades rather than
    corrupting the result.
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

        # None means auto-detect, which is what the multilingual default wants —
        # it identified Japanese at p=0.96 on a real track that the `.en` model
        # returned nothing for. Only pinned when an `.en` model is configured,
        # where the language is not in question.
        language = None if not _MODEL_NAME.endswith(".en") else "en"
        async with _SEMAPHORE:
            result = await asyncio.to_thread(
                _transcribe_sync, tmp_path, language, hint_lyrics)

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
