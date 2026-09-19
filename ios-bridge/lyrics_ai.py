"""Aria Lumi's audio-to-lyrics transcription.

The "listen and check" half of the lyrics system: the existing pipeline
(LRCLIB/lyrics.ovh fetch, manual .lrc/.txt import — see
NowPlayingView+Helpers.swift's loadLyrics()) only ever trusts fetched or
imported TEXT, with no way to verify it actually matches a given track, and
no way to produce anything at all for a user's own unreleased/personal
recording that no lyrics database has ever heard of. This module has Aria
actually listen to the audio (Gemini's native audio understanding) and
either transcribes it from scratch or, when candidate text is available,
corrects and re-times it against what's really in the recording.

Same failure contract as intelligence.py's call_intelligence: returns None
on any failure (no API key, rate limit, bad response) — every caller
already has "no AI-generated lyrics for this track" as a safe, pre-existing
fallback, since none of the existing lyrics paths depend on this.
"""

import asyncio
import contextlib
import json
import logging
import os
import tempfile
import time

from google.genai import errors as genai_errors
from google.genai import types as genai_types

import intelligence

logger = logging.getLogger("ios-bridge.lyrics_ai")

_LYRICS_SCHEMA = {
    "type": "object",
    "properties": {
        "instrumental": {"type": "boolean"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "lines": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "time_seconds": {"type": "number"},
                    "text": {"type": "string"},
                },
                "required": ["time_seconds", "text"],
            },
        },
    },
    "required": ["instrumental", "confidence", "lines"],
}

_SYSTEM_PROMPT = """\
You are transcribing lyrics for a music player's synced-lyrics display.
Listen to the attached audio track carefully and produce a line-by-line
transcription of exactly what is sung or rapped, each line tagged with the
timestamp (in seconds from the start of the track) at which that line
actually begins in the audio. Timestamps must reflect the REAL audio, not
guesses from a lyrics database — treat your own ears as the source of
truth.

If existing candidate lyrics text is provided below, use it as a starting
point (it saves you re-transcribing wording you can already reuse), but you
MUST correct any word, line order, or line count where it doesn't match
what you actually hear in the audio, and you must derive every timestamp
from the audio yourself, since candidate text never comes with real timing.
Do not invent lines that aren't actually present in the audio, and do not
omit lines that are present.

"track_duration_seconds" is the track's exact measured length. Every
timestamp you return MUST fall inside it — the last line must begin before
the track ends, not after. Timestamps past the end are worse than useless:
those lines can never be shown, and their presence means the earlier ones
are stretched out of step with the music too. Check your final line against
this number before answering, and if your timings run past it, re-listen
and correct them rather than scaling them. Distribute timestamps according
to where words actually land in the audio, not evenly across the track.

If the track is instrumental (no sung/spoken words) or you cannot make out
any lyrics with reasonable confidence, set "instrumental" to true (only if
there are no words at all) and return an empty "lines" array, and set
"confidence" to "low" — never fabricate lyrics you aren't reasonably sure
of; a user's own personal recording deserves an honest "couldn't make this
out" over confidently wrong text.
"""


# Transient, worth-retrying HTTP statuses. 503 is the one that matters in
# practice: Gemini returns "This model is currently experiencing high demand.
# Spikes in demand are usually temporary. Please try again later." and this
# module treated it exactly like a permanent failure — one 503 and the whole
# job returned None, surfacing to the user as "Lyrics transcription isn't
# available right now". Measured against real cloud-backed-up tracks, a single
# retry a few seconds later routinely succeeds on the same model: transcription
# itself works fine (correct wording, sensible timestamps), it was just being
# abandoned at the first sign of load. NOT retried: 400 (bad request), 404
# (dead model) and 429 (quota) — those don't get better by asking again, and
# 429 in particular is what intelligence.py's own per-task cooldown exists for.
_RETRYABLE_STATUSES = frozenset({500, 502, 503, 504})

# Tried in order. The primary is whatever the rest of the app is configured to
# use; the fallback is a different model generation, which matters because the
# 503s are per-model load — during one overload window the primary failed while
# this one answered immediately. Mirrors the ARIA_GEMINI_FALLBACK_MODELS
# pattern the Aria bot already uses for the same class of outage.
_FALLBACK_MODEL = os.getenv("LUMISOUND_GEMINI_LYRICS_FALLBACK_MODEL", "gemini-3.5-flash")

# ---------------------------------------------------------------------------
# Windowed transcription
# ---------------------------------------------------------------------------
#
# Asking for timestamps across a whole track is what made them inaccurate. The
# model transcribes the WORDS well; what it cannot do reliably is say where a
# line sits in absolute time four minutes into a recording. Checked against
# human-made LRCLIB timings, whole-track output drifts badly and can run off the
# end of the song entirely — answering a three-and-a-half minute track with a
# final line past the five minute mark.
#
# So the long range is removed rather than argued with. The track is cut into
# short windows, each transcribed on its own with timestamps RELATIVE to that
# window, and the window's start offset — which is exact, because ffmpeg cut it —
# is added back. The model then only has to localise within one window, and the
# error can no longer accumulate across the track.
#
# The cost is one model call per window instead of one per track. Windows are
# deliberately long enough to keep that count low and to give the model musical
# context to work with, and run concurrently so wall-clock time stays close to
# the single-call version.
_CHUNK_SECONDS = float(os.getenv("LUMISOUND_LYRICS_CHUNK_SECONDS", "60"))
# Overlap so a line straddling a cut is heard whole by at least one window. Lines
# duplicated across the seam are merged afterwards.
_CHUNK_OVERLAP_SECONDS = 6.0
# Below this there is no long range to remove, so a single call is both cheaper
# and better (it hears the whole song at once).
_CHUNK_MIN_TRACK_SECONDS = 90.0
_CHUNK_CONCURRENCY = int(os.getenv("LUMISOUND_LYRICS_CHUNK_CONCURRENCY", "3"))
# Hard ceiling on model calls for one track. Daily request allowances are per
# model and shared by every user of a deployment, so a per-track call count that
# scales with track length is the wrong shape: one long track should not be able
# to consume a meaningful share of what everyone else needs. Windows are WIDENED
# to fit under this cap rather than the track being left partly uncovered, so a
# long track gets coarser windows instead of no windows.
_CHUNK_MAX_WINDOWS = int(os.getenv("LUMISOUND_LYRICS_MAX_WINDOWS", "4"))

_CHUNK_SYSTEM_PROMPT = """\
You are transcribing lyrics for a music player's synced-lyrics display.

The attached audio is a SHORT EXCERPT from the middle of a longer track, not
the whole song. Transcribe exactly what is sung or rapped in THIS excerpt,
line by line.

Every timestamp must be in seconds measured from the START OF THIS EXCERPT —
not from the start of the full track. The excerpt begins at 0.0 and its length
is given as "excerpt_duration_seconds"; no timestamp may fall outside that
range. Getting these right is the entire purpose of this request: the words
are usually easy, the timing is what matters, so listen for the moment each
line's first word actually begins and report that.

The excerpt may begin or end mid-phrase. Include a partial line if you can
make out words in it; do not invent words to complete it. If there are no
sung or spoken words in this excerpt at all (an intro, a solo, an outro), set
"instrumental" to true and return an empty "lines" array — that is a normal,
expected answer for many excerpts and is not a failure.

If candidate lyrics for the FULL track are provided, use them only to help
recognise wording you hear in this excerpt. Most of those lines belong to
other parts of the track; do not include any line you cannot actually hear
here, and do not try to cover all of them.
"""

_MAX_ATTEMPTS_PER_MODEL = 3
_RETRY_BACKOFF_SECONDS = (3.0, 9.0)
# Overall ceiling across every attempt and model. The per-call HTTP timeout
# (240s below) bounds one request, but nothing bounded the sequence — without
# this, a run of slow failures could keep a job "pending" for many minutes while
# the client politely polls. Failing at a known point is better than hanging.
_TOTAL_DEADLINE_SECONDS = 420.0


def _run_transcription(
    audio_bytes: bytes,
    mime_type: str,
    title: str,
    artist: str,
    hint_lyrics: str | None,
    model: str,
    duration_seconds: float | None,
) -> str:
    """The actual blocking Gemini call — run via asyncio.to_thread by the
    caller, same pattern intelligence.py's _run_gemini_request uses."""
    # The track's real length, measured from the audio (see
    # _probe_audio_duration in main.py). Without it the model has no anchor for
    # what "the end of the track" means and its timestamps drift off the end —
    # observed running as much as 70% past a track's real duration. Every line
    # after the real end is unreachable, and the ones before it are stretched,
    # which is what makes lyrics scroll out of step with the music.
    user_text = {
        "title": title,
        "artist": artist,
        "candidate_lyrics": hint_lyrics or None,
        "track_duration_seconds": round(duration_seconds, 2) if duration_seconds else None,
    }
    parts: list[genai_types.Part] = [
        genai_types.Part.from_text(text=json.dumps(user_text)),
        genai_types.Part.from_bytes(data=audio_bytes, mime_type=mime_type),
    ]
    config = genai_types.GenerateContentConfig(
        system_instruction=intelligence.ARIA_PERSONA + "\n" + _SYSTEM_PROMPT,
        response_mime_type="application/json",
        response_schema=_LYRICS_SCHEMA,
        # Native-audio transcription of a whole track is a much slower call
        # than the text-only Gemini calls elsewhere in this file (audio
        # bytes for a full 3-5 min track, not just a text prompt) and had NO
        # explicit timeout at all before this, relying on the SDK default —
        # a hung/slow request could run indefinitely inside the background
        # job below with nothing to ever mark it failed. 240s comfortably
        # covers a long track while still guaranteeing the job eventually
        # resolves either way. (milliseconds, per google-genai's HttpOptions)
        http_options=genai_types.HttpOptions(timeout=240_000),
    )
    response = intelligence._client.models.generate_content(
        model=model,
        contents=parts,
        config=config,
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response")
    return text


# How far past the measured end of the track the last line may sit before the
# whole set of timings is treated as untrustworthy. A couple of seconds covers an
# honest disagreement about where a final word lands or a duration read off a
# slightly different encode; anything beyond it is not a rounding difference.
_TIMING_OVERRUN_TOLERANCE = 3.0


def timings_are_plausible(lines: list, duration_seconds: float | None) -> bool:
    """Whether a transcription's timestamps can be believed enough to present
    as SYNCED lyrics.

    Wrong timings are worse than no timings. Unsynced words render as a plain
    block that is honest about what it is, whereas wrong ones scroll confidently
    out of step with the music and, because Aria's output is stored as the
    user's own synced lyrics, take priority over a genuinely-synced version from
    LRCLIB. So this gates presentation, not the words themselves.

    Only checks what can be checked without ears: that the lines fall inside the
    track. It cannot catch timings that are wrong but in-range — the prompt and
    the duration hint are what address those.
    """
    if not lines or not duration_seconds or duration_seconds <= 0:
        # Nothing measured to check against; the words still stand.
        return True
    times = [
        float(entry.get("time_seconds", 0) or 0)
        for entry in lines
        if isinstance(entry, dict) and str(entry.get("text", "")).strip()
    ]
    if not times:
        return True
    return max(times) <= duration_seconds + _TIMING_OVERRUN_TOLERANCE


def _chunk_windows(duration: float) -> list[tuple[float, float]]:
    """(start, length) windows covering `duration`, with overlap between them.

    The final window is merged into its predecessor when it would be a sliver:
    a 4-second tail is not worth a model call, and a window shorter than the
    overlap carries almost nothing the previous one didn't already hear.
    """
    # Widened when the track is long enough that fixed-size windows would exceed
    # the per-track call ceiling — see `_CHUNK_MAX_WINDOWS`. A coarser window is
    # still a far shorter span for the model to localise within than the whole
    # track, so this degrades accuracy gently rather than falling back to nothing.
    step = max(_CHUNK_SECONDS, duration / _CHUNK_MAX_WINDOWS)

    windows: list[tuple[float, float]] = []
    start = 0.0
    while start < duration:
        length = min(step + _CHUNK_OVERLAP_SECONDS, duration - start)
        windows.append((start, length))
        start += step
    if len(windows) >= 2 and windows[-1][1] <= _CHUNK_OVERLAP_SECONDS + 1.0:
        s, _ = windows[-2]
        windows[-2] = (s, duration - s)
        windows.pop()
    return windows


async def _cut_chunk(src_path: str, start: float, length: float) -> bytes | None:
    """One window of the track as m4a bytes.

    Re-encoded rather than stream-copied: a copy can only cut on a container
    packet boundary, so the real start would drift from the requested one by up
    to a packet — and this window's start offset is precisely what makes the
    merged timestamps exact. `-ss` before `-i` so ffmpeg seeks rather than
    decoding the whole file for every window.
    """
    out_path = f"{src_path}.{int(start)}.m4a"
    try:
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-y", "-v", "quiet",
            "-ss", f"{start:.3f}", "-t", f"{length:.3f}",
            "-i", src_path,
            "-vn", "-ac", "1", "-ar", "24000", "-c:a", "aac", "-b:a", "48k",
            out_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        _, err = await asyncio.wait_for(proc.communicate(), timeout=90.0)
        if proc.returncode != 0 or not os.path.exists(out_path):
            logger.warning("lyrics chunk cut failed at %.1fs: %s",
                           start, err.decode(errors="replace")[-200:])
            return None
        with open(out_path, "rb") as f:
            return f.read()
    except Exception:
        logger.exception("lyrics chunk cut raised at %.1fs", start)
        return None
    finally:
        with contextlib.suppress(OSError):
            os.unlink(out_path)


async def _transcribe_one_chunk(
    chunk_bytes: bytes, start: float, length: float, title: str, artist: str,
    hint_lyrics: str | None, models: list[str],
) -> list[dict]:
    """Lines from one window, shifted into whole-track time.

    Takes the whole model CHAIN, not a single model. Hardcoding the primary here
    made the entire windowed path collapse the moment that model was rate-limited:
    every window 429'd, the run produced nothing, and it silently fell back to
    whole-track without saying so. Rate limits are exactly when a fallback model
    is most needed, so the one path that ignored the chain was the one that needed
    it most.
    """
    user_text = {
        "title": title,
        "artist": artist,
        "candidate_lyrics": hint_lyrics or None,
        "excerpt_duration_seconds": round(length, 2),
    }
    def _call(model: str) -> str:
        parts = [
            genai_types.Part.from_text(text=json.dumps(user_text)),
            genai_types.Part.from_bytes(data=chunk_bytes, mime_type="audio/mp4"),
        ]
        config = genai_types.GenerateContentConfig(
            system_instruction=intelligence.ARIA_PERSONA + "\n" + _CHUNK_SYSTEM_PROMPT,
            response_mime_type="application/json",
            response_schema=_LYRICS_SCHEMA,
            http_options=genai_types.HttpOptions(timeout=120_000),
        )
        response = intelligence._client.models.generate_content(
            model=model, contents=parts, config=config)
        return (response.text or "").strip()

    for model in models:
        for attempt in range(1, 3):
            try:
                parsed = json.loads(await asyncio.to_thread(_call, model))
                lines = parsed.get("lines")
                if not isinstance(lines, list):
                    return []
                out: list[dict] = []
                for entry in lines:
                    if not isinstance(entry, dict):
                        continue
                    text = str(entry.get("text", "")).strip()
                    if not text:
                        continue
                    rel = float(entry.get("time_seconds", 0) or 0)
                    # A timestamp outside the window is the model ignoring the
                    # one instruction that matters here, and shifting it would
                    # place the line somewhere it definitely is not. Dropped, so
                    # a bad window costs its own lines rather than corrupting the
                    # whole track's timeline.
                    if rel < -1.0 or rel > length + 1.0:
                        continue
                    out.append({"time_seconds": start + max(0.0, rel), "text": text})
                return out
            except genai_errors.APIError as exc:
                code = getattr(exc, "code", None)
                # 429 is quota, not load: this model has nothing left to give, so
                # move to the next one in the chain rather than retrying it.
                if code == 429:
                    logger.warning("lyrics chunk at %.1fs: %s is rate-limited, trying next model",
                                   start, model)
                    break
                if code not in _RETRYABLE_STATUSES or attempt == 2:
                    logger.warning("lyrics chunk at %.1fs failed on %s: %s", start, model, exc)
                    break
                await asyncio.sleep(_RETRY_BACKOFF_SECONDS[0])
            except Exception:
                logger.exception("lyrics chunk at %.1fs raised on %s", start, model)
                return []
    return []


def _merge_chunk_lines(groups: list[list[dict]]) -> list[dict]:
    """Flattens windows into one timeline, dropping seam duplicates.

    Overlap means a line near a cut can be reported by two windows. A repeat is
    identified by the same normalised text landing within the overlap of one
    already kept — deliberately not by text alone, since choruses legitimately
    repeat the same words later in the song and must stay separate lines.
    """
    merged: list[dict] = []
    for line in sorted((l for g in groups for l in g), key=lambda l: l["time_seconds"]):
        key = " ".join(line["text"].lower().split())
        # Scanned backwards by TIME rather than by a fixed number of entries: in
        # a dense passage (rapid ad-libs, a stacked chorus) a fixed lookback can
        # be exhausted while still inside the overlap, letting a seam duplicate
        # through. Stops as soon as it is further back than the overlap can
        # reach, so this stays cheap.
        dup = False
        for kept in reversed(merged):
            if line["time_seconds"] - kept["time_seconds"] > _CHUNK_OVERLAP_SECONDS:
                break
            if " ".join(kept["text"].lower().split()) == key:
                dup = True
                break
        if not dup:
            merged.append(line)
    return merged


async def _transcribe_windowed(
    audio_bytes: bytes, title: str, artist: str, hint_lyrics: str | None,
    duration_seconds: float, models: list[str],
) -> dict | None:
    """Whole-track transcription assembled from per-window transcriptions."""
    windows = _chunk_windows(duration_seconds)
    if len(windows) < 2:
        return None

    src_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".src", delete=False) as tmp:
            tmp.write(audio_bytes)
            src_path = tmp.name

        semaphore = asyncio.Semaphore(max(1, _CHUNK_CONCURRENCY))

        async def one(start: float, length: float) -> list[dict]:
            async with semaphore:
                chunk = await _cut_chunk(src_path, start, length)
                if chunk is None:
                    return []
                return await _transcribe_one_chunk(
                    chunk, start, length, title, artist, hint_lyrics, models)

        groups = await asyncio.gather(*(one(s, l) for s, l in windows))
    finally:
        if src_path:
            with contextlib.suppress(OSError):
                os.unlink(src_path)

    produced = sum(1 for g in groups if g)
    merged = _merge_chunk_lines(list(groups))
    logger.info(
        "lyrics windowed transcription: %d window(s), %d produced lines, %d lines merged for %r",
        len(windows), produced, len(merged), title,
    )
    # Some windows are legitimately empty (intro, solo, outro), but if almost
    # none produced anything the run is a failure rather than an instrumental
    # track — let the caller fall back to a whole-track attempt.
    if not merged or produced < max(1, len(windows) // 3):
        return None
    return {
        "instrumental": False,
        "confidence": "medium",
        "lines": merged,
        "windowed": True,
    }


async def transcribe_lyrics(
    audio_bytes: bytes,
    mime_type: str,
    title: str,
    artist: str,
    hint_lyrics: str | None = None,
    duration_seconds: float | None = None,
) -> dict | None:
    """Returns {"instrumental": bool, "confidence": str, "lines": [{"time_seconds": float, "text": str}]},
    or None on any failure — no API key configured, a Gemini error, or an
    unparseable response.

    `duration_seconds` is the track's measured length. It is both given to the
    model as an anchor and used to reject timings that land outside the track —
    see `timings_are_plausible`.
    """
    if intelligence._client is None:
        return None

    started = time.monotonic()
    models = [intelligence.INTELLIGENCE_MODEL]
    if _FALLBACK_MODEL and _FALLBACK_MODEL != intelligence.INTELLIGENCE_MODEL:
        models.append(_FALLBACK_MODEL)

    # Windowing is the REPAIR path, not the first move.
    #
    # It is the better way to get accurate timestamps (see the "Windowed
    # transcription" block above), but it costs one model call per window where a
    # whole-track pass costs one in total. Request allowances are finite and
    # shared across everyone using a deployment, so making windowing the default
    # would exhaust them several times faster and lyrics generation would simply
    # stop working sooner — a worse outcome for a listener than timing that is
    # sometimes off.
    #
    # So the cheap pass runs first, and windowing is spent only when that pass
    # produces timings that are provably wrong (they fall outside the track).
    # Crucially this does not add cost on top: the whole-track path used to
    # RETRY itself up to three times per model on exactly that failure, re-rolling
    # the same dice with the same prompt. Those attempts are now spent on windows
    # instead — the same budget, aimed at something structurally better.
    whole_track_result: dict | None = None

    for model in models:
        for attempt in range(1, _MAX_ATTEMPTS_PER_MODEL + 1):
            if time.monotonic() - started > _TOTAL_DEADLINE_SECONDS:
                logger.warning("transcribe_lyrics: giving up after %.0fs", time.monotonic() - started)
                return None
            try:
                text = await asyncio.to_thread(
                    _run_transcription, audio_bytes, mime_type, title, artist, hint_lyrics,
                    model, duration_seconds,
                )
                parsed = json.loads(text)
                if not isinstance(parsed.get("lines"), list):
                    # A structurally wrong response won't become right on a
                    # retry — the model answered, just not in the shape asked
                    # for. Bail rather than burning the retry budget.
                    logger.warning("transcribe_lyrics: %s returned no usable 'lines' array", model)
                    return None

                # Timings that run off the end of the track. Retried, because
                # unlike a malformed response this is the model being sloppy
                # rather than misunderstanding the task, and a re-listen with the
                # same prompt does sometimes land inside the track. `timings_ok`
                # is carried on the result so the caller can fall back to
                # presenting the words unsynced instead of pretending the
                # timestamps mean something.
                parsed["timings_ok"] = timings_are_plausible(parsed["lines"], duration_seconds)
                if not parsed["timings_ok"]:
                    last = max(
                        (float(e.get("time_seconds", 0) or 0) for e in parsed["lines"]
                         if isinstance(e, dict)),
                        default=0.0,
                    )
                    logger.warning(
                        "transcribe_lyrics: %s timings overrun the track (last line %.1fs "
                        "vs %.1fs duration) for %r — attempt %d/%d",
                        model, last, duration_seconds or 0, title, attempt, _MAX_ATTEMPTS_PER_MODEL,
                    )
                    # Deliberately NOT retried with the same prompt. Measured
                    # on one real track, two identical whole-track runs gave a
                    # 41s error and a 1.5s error — the variance is the method,
                    # not bad luck, so another roll is not a fix. Kept as the
                    # fallback and handed to the windowed repair below.
                    whole_track_result = parsed
                    break

                if attempt > 1 or model != intelligence.INTELLIGENCE_MODEL:
                    logger.info(
                        "transcribe_lyrics: succeeded on %s attempt %d (%.0fs elapsed)",
                        model, attempt, time.monotonic() - started,
                    )
                return parsed
            except genai_errors.APIError as exc:
                code = getattr(exc, "code", None)
                retryable = code in _RETRYABLE_STATUSES
                logger.warning(
                    "transcribe_lyrics: %s attempt %d/%d failed (code=%s, retryable=%s)",
                    model, attempt, _MAX_ATTEMPTS_PER_MODEL, code, retryable,
                )
                if not retryable:
                    break  # a different model won't fix a 400/404/429 either
                if attempt < _MAX_ATTEMPTS_PER_MODEL:
                    await asyncio.sleep(_RETRY_BACKOFF_SECONDS[min(attempt - 1, len(_RETRY_BACKOFF_SECONDS) - 1)])
            except json.JSONDecodeError:
                logger.warning("transcribe_lyrics: %s returned unparseable JSON", model)
                return None
            except Exception:
                logger.exception("transcribe_lyrics: unexpected failure on %s", model)
                return None
        if whole_track_result is not None:
            # Timings overran. Stop trying whole-track passes entirely — the
            # other model would be one more roll of the same dice, where the
            # windowed repair below is a different method. Saves that call for
            # the repair, which needs several.
            break

    # Whole-track timings were wrong. Spend the windowed repair on it.
    if whole_track_result is not None:
        if (_CHUNK_SECONDS > 0 and duration_seconds
                and duration_seconds >= _CHUNK_MIN_TRACK_SECONDS
                and time.monotonic() - started < _TOTAL_DEADLINE_SECONDS):
            logger.info("transcribe_lyrics: repairing %r with windowed transcription", title)
            try:
                windowed = await _transcribe_windowed(
                    audio_bytes, title, artist, hint_lyrics, duration_seconds, models,
                )
            except Exception:
                logger.exception("transcribe_lyrics: windowed repair raised for %r", title)
                windowed = None
            if windowed:
                windowed["timings_ok"] = timings_are_plausible(
                    windowed["lines"], duration_seconds)
                if windowed["timings_ok"]:
                    logger.info(
                        "transcribe_lyrics: windowed repair fixed %r — %d line(s) in %.0fs",
                        title, len(windowed["lines"]), time.monotonic() - started,
                    )
                    return windowed
                # Every window's timestamps were already clamped to its own span,
                # so an overrun here means the cut offsets disagree with the
                # measured duration — not something another pass fixes.
                logger.warning("transcribe_lyrics: windowed repair also overran for %r", title)
        # Returned with timings_ok already False, so the caller keeps the words
        # and presents them unsynced rather than showing wrong timing as if it
        # meant something.
        logger.warning("transcribe_lyrics: %r returning UNSYNCED — no trustworthy timing", title)
        return whole_track_result

    logger.warning("transcribe_lyrics: all models exhausted after %.0fs", time.monotonic() - started)
    return None
