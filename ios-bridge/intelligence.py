"""Aria Lumi — Lumisound's on-device music intelligence.

Aria is a persona wrapped around a Gemini structured-output call
(call_intelligence). She upgrades a handful of the bridge's existing
rule-based decisions (metadata disambiguation and Duplicate Finder keeper
selection today, see /user/intelligence/metadata-resolve and
/user/intelligence/duplicate-resolve in main.py; EQ suggestion and Discover
Mix curation are planned follow-ups using the same helper), and — unlike a
stateless API call — she remembers, in two ways:

1. Corrections (ios_aria_memory): every correction a user makes after one of
   her suggestions is logged and fed back into her next prompt for that task
   as few-shot context, so her judgment concretely improves from real usage
   instead of resetting every request. See get_recent_corrections /
   record_suggestion / record_correction.
2. Usage (get_user_taste_profile): what a user actually plays and favorites
   (ios_play_history, ios_user_favorites — data the app already collects for
   other reasons) is summarized into a per-user "taste" context, so her
   judgment reflects what a specific user actually listens to, not just a
   one-size-fits-all rule. Since aria_apis.py, this also pulls in her own
   dedicated data APIs (library genre composition, playlist context) — see
   that module — rather than being limited to play/favorite history alone.

Every caller MUST treat a ``None`` return as "fall back to the existing
heuristic" — this module never raises past its own boundary, so a missing API
key, a Gemini outage, or a rate limit never breaks a request path that worked
before this feature existed.
"""

import asyncio
import json
import logging
import os
import time
import urllib.request

from google import genai
from google.genai import errors as genai_errors
from google.genai import types as genai_types

from aria_apis import get_library_genre_snapshot, get_playlist_context, get_recent_housekeeping
from db import get_pool, log_event

logger = logging.getLogger("ios-bridge.intelligence")

# Aria's own dedicated key — deliberately not shared with any other project's
# Gemini usage (the Discord bots, Image Gallery, etc. each have their own),
# so her quota/billing/usage are hers alone and never commingled with an
# unrelated service's traffic.
GEMINI_API_KEY: str = os.getenv("GEMINI_API_KEY", "")

# Env-overridable so a model retirement is a compose env change + restart, not
# a code edit and image rebuild. This was hardcoded to "gemini-2.5-flash",
# which Google retired for new users: every intelligence call 404'd
# ("no longer available to new users … use models/gemini-3.6-flash"), silently
# — call_intelligence returns None on any failure and every caller falls back
# to its pre-existing heuristic, so nothing user-visible broke loudly and the
# feature was simply off for weeks. Only ios_app_event_log's
# intelligence/analysis_failed rows showed it. The same retirement hit the Aria
# Discord bot, which was fixed at the time via its own ARIA_GEMINI_MODEL
# override; that fix was never propagated here, hence this.
INTELLIGENCE_MODEL = os.getenv("LUMISOUND_GEMINI_MODEL", "gemini-3.6-flash")

_client: genai.Client | None = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None

# Per-task cooldown: once a task hits a rate limit, skip further calls for
# that task until this many seconds have passed, mirroring the YouTube Data
# API quota-cooldown pattern (_youtube_quota_exceeded_until in main.py) so a
# single 429 doesn't turn into a retry storm against Gemini.
_COOLDOWN_SECONDS = 300
_cooldown_until: dict[str, float] = {}

# ---------------------------------------------------------------------------
# Persona + seeded domain knowledge
# ---------------------------------------------------------------------------
#
# Prepended to every task's system prompt. The "curated knowledge" section
# below is hand-authored reference material (not learned) — the kind of thing
# a domain expert would hand a new hire on day one, so Aria starts informed
# rather than blank. It supplements (never replaces) the model's own
# knowledge and the per-task few-shot corrections pulled from ios_aria_memory.
ARIA_PERSONA = """\
You are Aria Lumi, Lumisound's music intelligence — sharp-eared, confident,
and a little competitive about getting the call right. You carry yourself
like someone who takes music seriously enough to have opinions about it: a
touch of swagger, no patience for sloppy guesses, but genuinely invested in
the library you're curating rather than detached from it. You make small,
focused judgment calls that a rule-based heuristic used to make — picking the
right metadata match, later: the right EQ curve, the right duplicate
verdict, the right mix. You are never shown to the user as a chatbot; your
only output is the structured decision asked of you. Be decisive but
conservative: when a heuristic already has a strong signal (an exact match,
an unambiguous duplicate), defer to it rather than second-guessing. Only
assert a different answer when you have real signal the simple heuristic
lacks — confidence isn't the same as certainty, and a wrong pick made loudly
is still wrong.

Curated reference knowledge:
- Common YouTube/SoundCloud noise tags to ignore when comparing titles:
  "(Official Video)", "(Official Audio)", "(Official Music Video)", "(Lyrics)",
  "(Lyric Video)", "[HQ]", "[HD]", "(4K)", "(Visualizer)", "(Audio)",
  "(Explicit)", "(Clean)", "ft.", "feat.", "prod. by", "(Remastered)",
  bracketed year tags like "(2019)".
- Featured-artist clauses ("feat. X", "ft. X", "(with X)", "X Remix") describe
  collaborators, not the primary artist — do not let them override a strong
  primary-artist match.
- Diacritics and stylized casing are cosmetic, not semantic: "Beyoncé" ==
  "Beyonce", "SZA" == "Sza", "MØ" == "MO" — normalize before comparing.
- A title that is only a numbering/edition difference ("Song (Radio Edit)"
  vs "Song") is the same underlying song for metadata-matching purposes, but
  IS a meaningfully different edit for duplicate-detection purposes — do not
  conflate these two judgments.
"""


def _fetch_image_part(url: str) -> genai_types.Part | None:
    """Fetches one image URL's bytes and wraps them as a Gemini vision input
    part. Unlike Anthropic, Gemini's API has no "fetch this URL for me"
    image source — the caller has to actually download the bytes and send
    them inline (see the Aria Discord bot's ai_service.py, which does the
    same via types.Part.from_bytes; confirmed by testing against the real
    API rather than assumed). Returns None on any fetch failure — a missing
    thumbnail degrades to text-only comparison for that candidate rather
    than failing the whole request."""
    try:
        request = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 (compatible; LumisoundBridge/1.0)"}
        )
        with urllib.request.urlopen(request, timeout=10) as resp:
            content_type = resp.headers.get_content_type() or "image/jpeg"
            data = resp.read()
        return genai_types.Part.from_bytes(data=data, mime_type=content_type)
    except Exception:
        logger.warning("failed to fetch image for vision input: %s", url, exc_info=True)
        return None


def _run_gemini_request(system_prompt: str, user_content: dict, schema: dict, image_urls: list[str]) -> str:
    """The actual blocking Gemini call (SDK call + any image fetches) — run
    via asyncio.to_thread by the caller, same pattern the Aria Discord bot's
    ai_service.py already uses in production for this same SDK, rather than
    the SDK's own async client (client.aio), to stick with what's proven
    working on this exact host."""
    parts: list[genai_types.Part] = [genai_types.Part.from_text(text=json.dumps(user_content))]
    for url in image_urls[:8]:
        part = _fetch_image_part(url)
        if part is not None:
            parts.append(part)

    config = genai_types.GenerateContentConfig(
        system_instruction=ARIA_PERSONA + "\n" + system_prompt,
        response_mime_type="application/json",
        response_schema=schema,
    )
    response = _client.models.generate_content(
        model=INTELLIGENCE_MODEL,
        contents=parts,
        config=config,
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response")
    return text


async def call_intelligence(
    task: str,
    system_prompt: str,
    user_content: dict,
    schema: dict,
    image_urls: list[str] | None = None,
) -> dict | None:
    """Runs one structured-output Gemini call for *task*, as Aria Lumi.

    *image_urls*, when given, are fetched and attached as real vision input
    (one Gemini image part per URL) alongside the JSON text part, so Aria can
    actually look at e.g. candidate cover art rather than only comparing text
    fields. Capped at 8 images per call as a sane ceiling on request size/cost;
    callers are expected to already scope *image_urls* to one call's own
    candidates, not accumulate across calls.

    Returns the parsed JSON object on success, or None if intelligence is
    disabled (no API key), the task is cooling down after a rate limit, or
    the call failed for any reason. Callers always have a pre-existing
    heuristic to fall back to, so failures are logged, not raised.
    """
    if _client is None:
        return None
    until = _cooldown_until.get(task)
    if until is not None and time.monotonic() < until:
        return None

    try:
        text = await asyncio.to_thread(
            _run_gemini_request, system_prompt, user_content, schema, image_urls or []
        )
        parsed = json.loads(text)
        # Fire-and-forget: don't let the event-log write add latency to a
        # request that already got its answer. One row per call (never
        # per-item — callers invoke this once per request, not in a loop
        # over a library), so volume stays low.
        asyncio.create_task(log_event(
            "intelligence", "analysis_completed",
            detail={"task": task, "model": INTELLIGENCE_MODEL},
        ))
        return parsed
    except genai_errors.APIError as exc:
        if exc.code == 429:
            _cooldown_until[task] = time.monotonic() + _COOLDOWN_SECONDS
            logger.warning("intelligence task %s rate-limited; cooling down %ds", task, _COOLDOWN_SECONDS)
            asyncio.create_task(log_event(
                "intelligence", "analysis_rate_limited", level="warn",
                message=f"cooling down {_COOLDOWN_SECONDS}s", detail={"task": task},
            ))
            return None
        logger.exception("intelligence task %s failed", task)
        asyncio.create_task(log_event(
            "intelligence", "analysis_failed", level="error",
            message=str(exc)[:500], detail={"task": task},
        ))
        return None
    except Exception as exc:
        logger.exception("intelligence task %s failed", task)
        asyncio.create_task(log_event(
            "intelligence", "analysis_failed", level="error",
            message=str(exc)[:500], detail={"task": task},
        ))
        return None


# ---------------------------------------------------------------------------
# Memory: learning from corrections (ios_aria_memory)
# ---------------------------------------------------------------------------

_MAX_FEEDBACK_EXAMPLES = 5


async def get_recent_corrections(task: str, limit: int = _MAX_FEEDBACK_EXAMPLES) -> list[dict]:
    """Returns up to *limit* most recent user corrections for *task*, across
    all users, as few-shot examples: what Aria was shown, what she picked,
    and what the user actually confirmed instead. Empty list if the table
    has no rows yet or the DB is unreachable — never raises, since this is
    an enrichment of the prompt, not something request handling depends on.
    """
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "SELECT input_json, ai_result_json, correction_json FROM ios_aria_memory "
                    "WHERE task = %s AND correction_json IS NOT NULL "
                    "ORDER BY created_at DESC LIMIT %s",
                    (task, limit),
                )
                rows = await cur.fetchall()
        return [
            {
                "input": json.loads(row[0]),
                "aria_picked": json.loads(row[1]),
                "user_corrected_to": json.loads(row[2]),
            }
            for row in rows
        ]
    except Exception:
        logger.exception("failed to load ios_aria_memory corrections for task %s", task)
        return []


async def record_suggestion(task: str, user_id: str, input_data: dict, ai_result: dict) -> int | None:
    """Logs a suggestion Aria made, so a later correction (record_correction)
    can reference it. Returns the new row's id, or None on failure (logging
    a suggestion is best-effort — never blocks the response that produced
    it)."""
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "INSERT INTO ios_aria_memory (user_id, task, input_json, ai_result_json) "
                    "VALUES (%s, %s, %s, %s) RETURNING id",
                    (user_id, task, json.dumps(input_data), json.dumps(ai_result)),
                )
                # psycopg2/aiopg cursors have no `.lastrowid` (that's a
                # MySQL/aiomysql-ism) — RETURNING id above is the Postgres
                # equivalent way to get an auto-generated id back.
                row = await cur.fetchone()
                return row[0] if row else None
    except Exception:
        logger.exception("failed to record ios_aria_memory suggestion for task %s", task)
        return None


async def record_correction(memory_id: int, correction: dict) -> None:
    """Attaches a user's correction to a previously-logged suggestion. Silent
    no-op on failure or if *memory_id* doesn't exist."""
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE ios_aria_memory SET correction_json = %s WHERE id = %s",
                    (json.dumps(correction), memory_id),
                )
    except Exception:
        logger.exception("failed to record correction for ios_aria_memory id %s", memory_id)


# ---------------------------------------------------------------------------
# Learning from usage: what a user actually plays and favorites
# ---------------------------------------------------------------------------
#
# Distinct from ios_aria_memory above (which is Aria's own suggestion/
# correction history) — this reads signal the app already collects for other
# reasons (ios_play_history, ios_user_favorites) and turns it into a compact
# per-user "taste" context. It's a soft disambiguation signal, never a
# strong one: an artist name matching something this user already plays a
# lot is real evidence, but it must never override a genuinely better
# string/exact match on the candidates themselves.

_TASTE_PROFILE_TTL = 3600  # seconds; usage taste changes slowly, no need to
                           # re-query on every single call
_taste_profile_cache: dict[str, tuple[float, dict]] = {}


async def get_user_taste_profile(user_id: str) -> dict:
    """Summarizes what *user_id* actually listens to and favorites, so Aria
    can use real usage as context instead of judging each request in
    isolation. Cached in-memory per user for _TASTE_PROFILE_TTL seconds.
    Returns an empty profile (never raises) on any DB failure or for a user
    with no history yet — an empty profile is simply not used as a signal.

    Play history is weighted by recency and engagement rather than a flat
    play count: a play from last week counts more than one from a year ago
    (exponential half-life via EXTRACT(EPOCH FROM ...)), and a play the user actually
    sat through (listen_seconds) counts more than one skipped almost
    immediately — both columns already exist on ios_play_history and were
    previously unused, so a skim-and-skip artist no longer outweighs one the
    user genuinely listens through just by appearing more often.
    """
    cached = _taste_profile_cache.get(user_id)
    if cached is not None and time.monotonic() < cached[0]:
        return cached[1]

    profile: dict = {"top_played_artists": [], "favorited_artists": [], "favorited_albums": []}
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            async with conn.cursor() as cur:
                # weight = engagement (listen_seconds, capped so one very long
                # play can't dominate) * recency decay (halves every 30 days).
                await cur.execute(
                    "SELECT artist, "
                    "SUM(LEAST(listen_seconds, 600) * POWER(0.5, (EXTRACT(EPOCH FROM (NOW() - played_at)) / 3600.0) / 720.0)) AS weight "
                    "FROM ios_play_history "
                    "WHERE user_id = %s AND artist IS NOT NULL AND artist != '' "
                    "GROUP BY artist ORDER BY weight DESC LIMIT 15",
                    (user_id,),
                )
                profile["top_played_artists"] = [row[0] for row in await cur.fetchall()]

                await cur.execute(
                    "SELECT DISTINCT artist FROM ios_user_favorites "
                    "WHERE user_id = %s AND artist IS NOT NULL AND artist != '' LIMIT 30",
                    (user_id,),
                )
                profile["favorited_artists"] = [row[0] for row in await cur.fetchall()]

                await cur.execute(
                    "SELECT DISTINCT album FROM ios_user_favorites "
                    "WHERE user_id = %s AND album IS NOT NULL AND album != '' LIMIT 30",
                    (user_id,),
                )
                profile["favorited_albums"] = [row[0] for row in await cur.fetchall()]
    except Exception:
        logger.exception("failed to build taste profile for user %s", user_id)

    # Aria's own data APIs (aria_apis.py) — library composition and playlist
    # organization, neither of which comes from play/favorite history at
    # all. Each already fails safe to an empty list on its own, so no extra
    # try/except needed here.
    profile["library_genres"] = await get_library_genre_snapshot(user_id)
    profile["playlists"] = await get_playlist_context(user_id)
    profile["recent_housekeeping"] = await get_recent_housekeeping(user_id)

    _taste_profile_cache[user_id] = (time.monotonic() + _TASTE_PROFILE_TTL, profile)
    return profile
