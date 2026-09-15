"""Reading inside Lumisound-locked (`.lms`) cloud tracks.

A locked file is the iOS app's own container: an 8-byte `LMSLOCK1` magic header
followed by the real audio XOR-masked with a fixed 24-byte key. To anything that
expects audio — ffmpeg, ffprobe, mutagen, AVFoundation — those bytes are noise.
That single fact is behind a whole family of "the server can't see it" problems:

  * artwork could only come from a thumbnail the phone uploaded separately,
    because the server could not read the cover embedded in the file;
  * `bpm` was only ever filled in by on-device analysis on the iPhone, so a
    library filled from tvOS or from cloud backup had it for almost nothing —
    which is what left Smart Playlists with nothing to build from.

This module gives the server the same read access the clients have.

**It never modifies a stored file.** The obvious reading of "unlock it, extract,
then lock it again" is to unmask the file in place and re-mask it afterwards,
and that is a genuinely dangerous way to do it: a crash, a restart or a full disk
between the two halves leaves the user's only copy in a state that matches
neither what the server expects nor what the client expects. Instead the masked
bytes are streamed into a temporary file, read from there, and the temporary file
is deleted — the original is opened read-only and is never rewritten, so there is
no window in which it can be left wrong. The net effect is the same and the
failure mode is "we learn nothing this time" instead of "the track is corrupt".
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import math
import os
import pathlib
import struct
import subprocess
import tempfile
import urllib.request

logger = logging.getLogger("ios-bridge")

# Must stay byte-identical to LumisoundLockFormat (iOS) and TVLockFormat (tvOS).
LOCK_MAGIC = b"LMSLOCK1"
LOCK_KEY = bytes([
    0x4C, 0x75, 0x6D, 0x69, 0x53, 0x6F, 0x75, 0x6E,
    0x64, 0x45, 0x78, 0x63, 0x6C, 0x75, 0x73, 0x69,
    0x76, 0x65, 0x4C, 0x6F, 0x63, 0x6B, 0x21, 0x21,
])

_CHUNK = 1024 * 1024


def is_locked(path: pathlib.Path) -> bool:
    """True when the file carries the lock header.

    A `.lms` extension is NOT sufficient: older versions of the iOS app produced
    plain-renamed `.lms` files with no header at all, and those are already
    readable. Both clients handle that case, so the server has to as well.
    """
    try:
        with open(path, "rb") as f:
            return f.read(len(LOCK_MAGIC)) == LOCK_MAGIC
    except OSError:
        return False


def _unmask_into(src: pathlib.Path, dst_fd: int) -> None:
    """Streams `src` through the XOR into an already-open descriptor.

    Chunked rather than `read()` + `bytes(...)`: these are whole music files, and
    a 40MB FLAC read into memory and XORed into a second 40MB buffer is 80MB per
    track — fine once, ruinous when a backfill walks five hundred of them inside
    a container with a memory limit.
    """
    key = LOCK_KEY
    keylen = len(key)
    offset = 0
    with open(src, "rb") as f:
        header = f.read(len(LOCK_MAGIC))
        if header != LOCK_MAGIC:
            # Legacy plain-renamed .lms — copy through untouched.
            os.write(dst_fd, header)
            while chunk := f.read(_CHUNK):
                os.write(dst_fd, chunk)
            return
        while chunk := f.read(_CHUNK):
            # Key phase must continue across chunk boundaries, so the repeating
            # key is rotated to wherever the previous chunk left it.
            phase = offset % keylen
            rotated = key[phase:] + key[:phase]
            pad = rotated * (len(chunk) // keylen + 2)
            os.write(dst_fd, bytes(b ^ k for b, k in zip(chunk, pad)))
            offset += len(chunk)


@contextlib.contextmanager
def readable_copy(path: pathlib.Path, suffix: str = ""):
    """Yields a path to a temporarily readable copy, deleted on exit.

    Unlocked files are yielded as-is with no copy at all — there is nothing to
    undo, and copying a file only to read it is wasted I/O on a disk that is
    already the slow part of every backfill.
    """
    if not is_locked(path):
        yield path
        return

    fd, tmp = tempfile.mkstemp(suffix=suffix or path.suffix, prefix="lms-")
    try:
        _unmask_into(path, fd)
        os.close(fd)
        fd = -1
        yield pathlib.Path(tmp)
    finally:
        if fd >= 0:
            with contextlib.suppress(OSError):
                os.close(fd)
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def inner_suffix(path: pathlib.Path) -> str:
    """The real container extension inside a lock, e.g. "Song.opus.lms" -> ".opus".

    ffmpeg and mutagen both use the extension as a demuxer hint, so handing them
    a temp file called `*.lms` makes them guess — and guess wrong for Ogg.
    """
    if path.suffix.lower() == ".lms":
        inner = pathlib.Path(path.stem).suffix
        if inner:
            return inner
    return path.suffix


# ---------------------------------------------------------------------------
# Artwork
# ---------------------------------------------------------------------------

_MIN_IMAGE_BYTES = 2048


def _ffmpeg_cover(audio: pathlib.Path) -> bytes | None:
    """Embedded cover art, via ffmpeg's attached-picture stream."""
    for mapping in ("0:v:0", "0:V:0"):
        out = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
        out.close()
        try:
            proc = subprocess.run(
                ["ffmpeg", "-v", "quiet", "-y", "-i", str(audio),
                 "-map", mapping, "-c:v", "mjpeg", "-frames:v", "1",
                 "-f", "image2", out.name],
                capture_output=True, timeout=60,
            )
            data = pathlib.Path(out.name).read_bytes() if proc.returncode == 0 else b""
            if len(data) > _MIN_IMAGE_BYTES:
                return data
        except (subprocess.SubprocessError, OSError):
            pass
        finally:
            with contextlib.suppress(OSError):
                os.unlink(out.name)
    return None


def _tag_artwork(audio: pathlib.Path) -> bytes | None:
    """Artwork reachable only through the tags, not through ffmpeg.

    Two sources ffmpeg will not give you:

      * FLAC/Ogg picture blocks that ffmpeg exposes inconsistently;
      * `lumisound_thumbnail`, a Vorbis comment the iOS app writes holding the
        artwork's URL. ffprobe does not print Ogg comments at all, which is
        precisely why this went unnoticed for so long — every tool the server
        used reported the file as having no artwork when it plainly listed one.
    """
    try:
        from mutagen import File as MutagenFile
    except ImportError:
        return None
    try:
        f = MutagenFile(str(audio))
    except Exception:
        return None
    if f is None:
        return None

    pics = getattr(f, "pictures", None)
    if pics:
        data = pics[0].data
        if len(data) > _MIN_IMAGE_BYTES:
            return data

    tags = f.tags or {}
    try:
        value = tags.get("lumisound_thumbnail")
    except Exception:
        value = None
    if isinstance(value, list):
        value = value[0] if value else None
    if not value:
        return None
    value = str(value).strip()

    if value.startswith("http"):
        data = _fetch(value)
        if data:
            return data
        # maxresdefault does not exist for every video; walk down the ladder so a
        # track gets the best art that actually exists rather than none.
        if "/vi/" in value:
            stem = value.rsplit("/", 1)[0]
            for size in ("maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"):
                data = _fetch(f"{stem}/{size}.jpg")
                if data:
                    return data
        return None

    # Tolerate a data: URI or bare base64, in case an older client wrote bytes.
    import base64
    try:
        payload = value.split(",", 1)[1] if value.startswith("data:") else value
        data = base64.b64decode(payload, validate=False)
        if data[:2] == b"\xff\xd8" or data[:8] == b"\x89PNG\r\n\x1a\n":
            return data
    except Exception:
        pass
    return None


def _fetch(url: str) -> bytes | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Lumisound/artwork"})
        with urllib.request.urlopen(req, timeout=20) as r:
            if r.status != 200:
                return None
            data = r.read()
        # YouTube serves a small grey placeholder for sizes that do not exist.
        return data if len(data) > _MIN_IMAGE_BYTES else None
    except Exception:
        return None


def extract_artwork(path: pathlib.Path) -> tuple[bytes | None, str]:
    """Best available artwork for a track, locked or not.

    Returns `(data, source)` so callers can report WHICH route produced it —
    the difference between "this library has no embedded art" and "we only ever
    looked in one place" is otherwise invisible.
    """
    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            data = _ffmpeg_cover(readable)
            if data:
                return data, "embedded"
            data = _tag_artwork(readable)
            if data:
                return data, "tag"
    except Exception as exc:
        logger.warning("extract_artwork failed for %s: %s", path.name, exc)
        return None, "error"
    return None, "none"


# ---------------------------------------------------------------------------
# Tempo
# ---------------------------------------------------------------------------

_BPM_SAMPLE_RATE = 11025
_BPM_MAX_SECONDS = 120
_BPM_MIN = 60.0
_BPM_MAX = 200.0


def _decode_mono(audio: pathlib.Path, seconds: int) -> bytes | None:
    """Decodes the middle of a track to 16-bit mono PCM.

    The MIDDLE, not the start: intros are frequently unrepresentative — a long
    ambient pad or a spoken lead-in gives a tempo that has nothing to do with the
    body of the song.
    """
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", str(audio)],
            capture_output=True, text=True, timeout=30,
        )
        duration = float((probe.stdout or "0").strip() or 0)
    except Exception:
        duration = 0.0

    start = max(0.0, (duration - seconds) / 2) if duration > seconds else 0.0
    try:
        proc = subprocess.run(
            ["ffmpeg", "-v", "quiet", "-ss", str(start), "-i", str(audio),
             "-t", str(seconds), "-ac", "1", "-ar", str(_BPM_SAMPLE_RATE),
             "-f", "s16le", "-"],
            capture_output=True, timeout=180,
        )
    except subprocess.SubprocessError:
        return None
    return proc.stdout if proc.returncode == 0 and proc.stdout else None


def estimate_bpm(path: pathlib.Path) -> float | None:
    """Estimates tempo, or None when the track has no steady beat to find.

    Method: an onset-strength envelope (positive frame-to-frame change in
    short-window energy — a beat is a sudden RISE, so falls are discarded),
    autocorrelated over the plausible tempo range. The lag with the strongest
    correlation is the beat period.

    Deliberately conservative about what it will claim. Returning a wrong tempo
    is worse than returning nothing: a wrong value silently mis-sorts a track
    into the wrong Smart Playlist and beat-snaps a crossfade to a beat that is
    not there, and nothing downstream can tell it is wrong. So a weak or
    ambiguous peak yields None and the track is simply left without a BPM.
    """
    try:
        import numpy as np
    except ImportError:
        logger.warning("estimate_bpm: numpy unavailable")
        return None

    suffix = inner_suffix(path)
    try:
        with readable_copy(path, suffix=suffix) as readable:
            raw = _decode_mono(readable, _BPM_MAX_SECONDS)
    except Exception as exc:
        logger.warning("estimate_bpm failed for %s: %s", path.name, exc)
        return None
    if not raw or len(raw) < 4 * _BPM_SAMPLE_RATE * 2:  # need a few seconds
        return None

    samples = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
    if samples.size == 0:
        return None

    # ~11.6ms frames: short enough to resolve a beat, long enough to smooth
    # individual waveform cycles out of the envelope.
    hop = 128
    frames = samples.size // hop
    if frames < 64:
        return None
    energy = np.sqrt((samples[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1))

    # Onset strength: rises only. Falls carry no beat information and, left in,
    # make the envelope correlate with itself at every lag.
    flux = np.diff(energy, prepend=energy[:1])
    flux[flux < 0] = 0
    if flux.max() <= 0:
        return None
    flux = flux - flux.mean()

    frame_rate = _BPM_SAMPLE_RATE / hop
    min_lag = int(frame_rate * 60.0 / _BPM_MAX)
    max_lag = int(frame_rate * 60.0 / _BPM_MIN)
    if max_lag >= flux.size:
        max_lag = flux.size - 1
    if min_lag < 1 or max_lag <= min_lag:
        return None

    corr = np.correlate(flux, flux, mode="full")[flux.size - 1:]
    window = corr[min_lag:max_lag + 1]
    if window.size == 0 or corr[0] <= 0:
        return None

    best = int(np.argmax(window))
    peak = window[best]
    # Normalised against zero-lag energy, so the threshold means the same thing
    # for a quiet track as for a loud one.
    strength = float(peak / corr[0])
    if strength < 0.10:
        return None

    lag = min_lag + best
    bpm = 60.0 * frame_rate / lag

    # Fold into a musically sensible range. Autocorrelation cannot tell a tempo
    # from half or double it — both are real peaks — so 170 for a 85bpm track is
    # a coin toss rather than an error. Preferring the 70-140 band is what a
    # listener would usually call the tempo.
    while bpm > 140 and bpm / 2 >= _BPM_MIN:
        bpm /= 2
    while bpm < 70 and bpm * 2 <= _BPM_MAX:
        bpm *= 2
    if not (_BPM_MIN <= bpm <= _BPM_MAX):
        return None
    return round(bpm, 1)


# ---------------------------------------------------------------------------
# Async wrappers — both of the above block on ffmpeg and on disk.
# ---------------------------------------------------------------------------

async def extract_artwork_async(path: pathlib.Path) -> tuple[bytes | None, str]:
    return await asyncio.to_thread(extract_artwork, path)


async def estimate_bpm_async(path: pathlib.Path) -> float | None:
    return await asyncio.to_thread(estimate_bpm, path)
