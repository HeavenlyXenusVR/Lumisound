#!/usr/bin/env bash
#
# Host-only YouTube cookie refresh.
#
# This script intentionally does not run in the ios-bridge container. Browser
# cookie databases and their keyrings must stay on the host, and the generated
# file is written atomically so a failed refresh never replaces a previously
# working file with an empty/partial one.
#
# Two ways to obtain a fresh jar, tried in this order:
#
#   1. BROWSER mode — `YTDLP_BROWSER` set: read the local browser profile
#      directly (the original behaviour, unchanged).
#
#   2. INBOX mode — no `YTDLP_BROWSER`: adopt the newest `cookies*.txt` that
#      has appeared in `YTDLP_COOKIE_INBOX` (default ~/Downloads) and is newer
#      than the installed jar. Browser mode cannot work on every host — this
#      one has no harvestable profile at all (only chromium is installed; one
#      profile holds no YouTube session and the other fails with "cannot
#      decrypt v11 cookies: no key found", having no keyring) — and exporting
#      a jar from a signed-in browser by hand is then the only way to get one.
#      Before this, that manual export had to be copied into place by hand
#      every time too, so in practice nothing refreshed the cookies at all and
#      they sat stale for weeks while YouTube served sign-in walls.
#
# Both modes converge on the same validation and the same atomic install
# below, so an export that is malformed, anonymous, or already dead can never
# replace a working jar.
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COOKIE_FILE="${YTDLP_COOKIES_FILE:-$SCRIPT_DIR/cookies.txt}"
CACHE_DIR="${YTDLP_CACHE_DIR:-$SCRIPT_DIR/cache/yt-dlp}"
# NOT yt-dlp's own BaW_jenozKc test video, which this defaulted to: it now
# returns "This video is unavailable", so every liveness probe below failed for
# reasons unrelated to the cookies and fell through to installing unchecked.
# The probe is only as good as a reference URL that genuinely resolves.
REFRESH_URL="${YTDLP_COOKIE_REFRESH_URL:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"
YTDLP_BROWSER="${YTDLP_BROWSER:-}"
YTDLP_BIN="${YTDLP_BIN:-$(command -v yt-dlp || true)}"
COOKIE_INBOX="${YTDLP_COOKIE_INBOX:-$HOME/Downloads}"

if [[ -z "$YTDLP_BIN" || ! -x "$YTDLP_BIN" ]]; then
    printf '%s\n' "yt-dlp is required on the host (set YTDLP_BIN if it is not on PATH)." >&2
    exit 2
fi

COOKIE_DIR="$(dirname -- "$COOKIE_FILE")"
mkdir -p -- "$COOKIE_DIR" "$CACHE_DIR"

# A lock prevents a timer run and a sentinel-triggered run from reading the
# browser database concurrently. The lock contains no cookie data.
exec 9>"$CACHE_DIR/.cookies_refresh.lock"
if ! flock -n 9; then
    exit 0
fi

STAGING_DIR="$COOKIE_DIR/.cookies-refresh.$$"
cleanup() {
    rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT
if ! mkdir -- "$STAGING_DIR"; then
    printf '%s\n' "Another cookie refresh is already staging a file." >&2
    exit 0
fi

STAGED_COOKIE_FILE="$STAGING_DIR/cookies.txt"
ERROR_FILE="$STAGING_DIR/yt-dlp.stderr"

if [[ -n "$YTDLP_BROWSER" ]]; then
    # yt-dlp performs the browser extraction locally and writes a Netscape cookie
    # jar to --cookies. Suppress its output: diagnostics must never include cookie
    # values in service logs.
    if ! "$YTDLP_BIN" \
        --cookies-from-browser "$YTDLP_BROWSER" \
        --cookies "$STAGED_COOKIE_FILE" \
        --skip-download \
        --no-playlist \
        --no-warnings \
        "$REFRESH_URL" \
        >/dev/null 2>"$ERROR_FILE"; then
        printf '%s\n' "Browser cookie refresh failed; keeping the existing cookie file." >&2
        exit 1
    fi

    if [[ ! -s "$STAGED_COOKIE_FILE" ]]; then
        printf '%s\n' "Browser cookie refresh produced no cookie file; keeping the existing file." >&2
        exit 1
    fi
else
    # INBOX mode. Pick the newest cookies*.txt in the inbox, and only proceed if
    # it is strictly newer than the jar already installed — otherwise every
    # timer tick would re-adopt and re-verify the same export forever. Globs are
    # matched with a nullglob'd array so a filename containing spaces (the
    # browser's own "cookies (2).txt" does) survives intact.
    shopt -s nullglob
    candidates=("$COOKIE_INBOX"/cookies*.txt)
    shopt -u nullglob
    if (( ${#candidates[@]} == 0 )); then
        printf '%s\n' "No cookies*.txt in $COOKIE_INBOX and no YTDLP_BROWSER set; nothing to do." >&2
        exit 0
    fi

    NEWEST=""
    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate" ]] || continue
        if [[ -z "$NEWEST" || "$candidate" -nt "$NEWEST" ]]; then
            NEWEST="$candidate"
        fi
    done
    if [[ -z "$NEWEST" ]]; then
        printf '%s\n' "No readable cookie export in $COOKIE_INBOX; nothing to do." >&2
        exit 0
    fi
    if [[ -e "$COOKIE_FILE" && ! "$NEWEST" -nt "$COOKIE_FILE" ]]; then
        # Already adopted (the install below touches COOKIE_FILE so its mtime
        # is the install time, which always beats the export's).
        #
        # Nothing new to adopt — but the sentinel may still be sitting there,
        # and the .path unit re-triggers this service for as long as it exists,
        # so a sentinel nobody clears means a permanent trigger loop that only
        # the service's rate limit contains. The sentinel is written on a
        # *symptom* (a sign-in wall, which YouTube also serves for plain IP
        # rate-limiting), so it can outlive the problem. Verify the jar that is
        # actually installed: if it still authenticates, the sentinel is stale
        # and clearing it is correct. If it doesn't, leave it — it is telling
        # the truth and a fresh export is genuinely needed.
        if [[ -e "$CACHE_DIR/.cookies_stale" && "${YTDLP_COOKIE_SKIP_LIVE_CHECK:-0}" != "1" ]]; then
            if "$YTDLP_BIN" \
                --cookies "$COOKIE_FILE" \
                --flat-playlist \
                --playlist-items 1 \
                --skip-download \
                --ignore-no-formats-error \
                --print "%(id)s" \
                "${YTDLP_COOKIE_PROBE_URL:-https://www.youtube.com/playlist?list=WL}" \
                >/dev/null 2>"$ERROR_FILE"; then
                rm -f -- "$CACHE_DIR/.cookies_stale"
                printf '%s\n' "Installed cookies still authenticate; cleared a stale sentinel." >&2
            else
                printf '%s\n' "Installed cookies no longer authenticate and no newer export is available in $COOKIE_INBOX — export a fresh cookies.txt from a signed-in browser." >&2
            fi
        fi
        exit 0
    fi

    cp -- "$NEWEST" "$STAGED_COOKIE_FILE"
    if [[ ! -s "$STAGED_COOKIE_FILE" ]]; then
        printf '%s\n' "Cookie export in $COOKIE_INBOX is empty; keeping the existing file." >&2
        exit 1
    fi
    if [[ "$(head -c 64 -- "$STAGED_COOKIE_FILE")" != *"Netscape HTTP Cookie File"* ]]; then
        printf '%s\n' "Cookie export is not a Netscape cookie file; keeping the existing file." >&2
        exit 1
    fi
fi

# Refuse to install an arbitrary or anonymous export. This is deliberately a
# structural check only; cookie contents are never printed or returned.
if ! grep -Eqi '(^|[[:space:]])(#HttpOnly_)?\.?(youtube\.com|www\.youtube\.com)([[:space:]]|$)' "$STAGED_COOKIE_FILE"; then
    printf '%s\n' "Refusing to install a cookie file without YouTube cookies." >&2
    exit 1
fi
if ! grep -Eqi '([[:space:]])(__Secure-)?(SID|HSID|SSID|APISID|SAPISID|LOGIN_INFO)([[:space:]]|$)' "$STAGED_COOKIE_FILE"; then
    printf '%s\n' "Refusing to install a cookie file without a YouTube session cookie." >&2
    exit 1
fi

# Liveness check. The structural checks above are NOT sufficient to know a jar
# works: YouTube invalidates a session server-side while the cookie records
# keep their original far-future expiry dates, so a completely dead jar still
# parses, still carries every session cookie, and still looks months from
# expiring. (The jar this replaced read `exp=1821996693` — well into 2027 —
# while yt-dlp reported "The provided YouTube account cookies are no longer
# valid. They have likely been rotated in the browser".) Judge by asking
# YouTube, never by reading expiry timestamps.
#
# The probe asks for the account's Watch Later playlist, which is visible ONLY
# to a signed-in session, so the exit status alone is a clean verdict: a live
# jar lists an entry and exits 0, a rotated one gets "The playlist does not
# exist" and exits 1. Probing an ordinary video instead does NOT work here —
# yt-dlp resolves those fine while signed out, and the host's yt-dlp is old
# enough that it never prints the "cookies are no longer valid" warning that
# newer builds (like the one inside the container) use to flag rotation, so
# there was no signal to match on. Nothing here can print cookie values.
#
# Refusing to install on a failed probe is the safe direction: a network
# outage looks the same as dead cookies, and in both cases keeping the current
# jar and retrying on the next tick loses nothing.
# Set YTDLP_COOKIE_SKIP_LIVE_CHECK=1 to install without network access.
PROBE_URL="${YTDLP_COOKIE_PROBE_URL:-https://www.youtube.com/playlist?list=WL}"
if [[ "${YTDLP_COOKIE_SKIP_LIVE_CHECK:-0}" != "1" ]]; then
    # --ignore-no-formats-error: this host's yt-dlp cannot run YouTube's JS
    # challenge solver, so media formats often fail to resolve. That says
    # nothing about whether the cookies authenticated, and without this the
    # probe failed on every jar, valid or not.
    if ! "$YTDLP_BIN" \
        --cookies "$STAGED_COOKIE_FILE" \
        --flat-playlist \
        --playlist-items 1 \
        --skip-download \
        --ignore-no-formats-error \
        --print "%(id)s" \
        "$PROBE_URL" \
        >/dev/null 2>"$ERROR_FILE"; then
        printf '%s\n' "Cookie export did not authenticate against YouTube (rotated, or network unreachable); keeping the existing file." >&2
        exit 1
    fi
fi

chmod 600 -- "$STAGED_COOKIE_FILE"
mv -f -- "$STAGED_COOKIE_FILE" "$COOKIE_FILE"
# Stamp the install time so INBOX mode's "newer than the installed jar" test
# above stops matching the export it just adopted.
touch -- "$COOKIE_FILE"
# The bridge only needs the sentinel while a refresh is pending. Remove it
# after the atomic replacement, never before a validated file is installed.
rm -f -- "$CACHE_DIR/.cookies_stale"
printf '%s\n' "YouTube cookies refreshed successfully."
