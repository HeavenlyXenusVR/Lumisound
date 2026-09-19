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
import json
import logging
import os
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
    # what "the end of the track" means and its timestamps drift off the end:
    # measured on two real tracks from this deployment, a 208s track came back
    # with its last line at 313s and a 243s track with its last line at 414s —
    # 70% past the end. Every line after the real end is unreachable, and the
    # ones before it are stretched, which is what made Aria's lyrics scroll out
    # of step with the music.
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
                    is_last_try = (attempt == _MAX_ATTEMPTS_PER_MODEL and model == models[-1])
                    if not is_last_try:
                        if attempt < _MAX_ATTEMPTS_PER_MODEL:
                            await asyncio.sleep(
                                _RETRY_BACKOFF_SECONDS[min(attempt - 1, len(_RETRY_BACKOFF_SECONDS) - 1)]
                            )
                            continue
                        break  # move on to the fallback model

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

    logger.warning("transcribe_lyrics: all models exhausted after %.0fs", time.monotonic() - started)
    return None
