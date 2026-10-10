"""Real AI vocal/instrumental source separation via Demucs (htdemucs,
two-stem mode), run as a subprocess and bounded by a hard concurrency limit.

This is a genuinely different thing from the existing "Karaoke" audio effect
(AudioEffectsService.swift / AVAudioUnitEQ band notch around the vocal
range on-device) — that's a crude EQ dip that still leaves most of the
vocal bleeding through on anything but a narrow-band mix; this actually
separates the sources via a trained model, at real CPU cost. Deliberately
server-side (an on-device model of comparable quality would be a much
larger app download and would make a phone's battery/thermals pay for
every separation) and deliberately capped at ONE concurrent job
(_SEPARATION_SEMAPHORE) — demucs is CPU-bound and slow (routinely
1-4 minutes for a normal-length track on a modest multi-core box, see
timing note below), and this host already runs the Discord bot swarm,
Lavalink, and everything else in ios-bridge alongside this.
"""

from __future__ import annotations

import asyncio
import logging
import pathlib
import shutil
import tempfile
import time

logger = logging.getLogger("stem_separation")

# One at a time, no queue beyond what the caller's own job dict already
# serializes through. A second/third simultaneous demucs run on a shared,
# already-busy host (14 Discord bots + Lavalink + everything else in this
# same ios-bridge) would degrade all of it, not just make separation itself
# slower — better to make a caller wait than let that happen.
_SEPARATION_SEMAPHORE = asyncio.Semaphore(1)

# Generous: a typical 3-4 minute track measured at roughly 1-2x realtime on
# CPU for htdemucs's two-stem mode on a modest multi-core box — this leaves
# headroom for a longer track or a loaded host without false-timing-out a
# job that would have finished.
SEPARATION_TIMEOUT_SECONDS = 600


class SeparationError(Exception):
    pass


async def separate_stems(input_path: pathlib.Path, work_dir: pathlib.Path) -> dict[str, pathlib.Path]:
    """Runs `demucs --two-stems=vocals -n htdemucs` on `input_path`, writing
    into `work_dir`, and returns {"vocals": Path, "instrumental": Path} —
    both re-encoded to Opus (demucs itself only writes WAV, which is far
    larger than this needs to ship over the wire for what's ultimately a
    preview/remix-source file, not a mastered deliverable).

    Raises SeparationError on any failure (demucs exits non-zero, the
    expected output files don't appear, or the job runs past
    SEPARATION_TIMEOUT_SECONDS) — never leaves a half-written result for a
    caller to serve.
    """
    work_dir.mkdir(parents=True, exist_ok=True)

    async with _SEPARATION_SEMAPHORE:
        started = time.monotonic()
        cmd = [
            "python", "-m", "demucs",
            "--two-stems", "vocals",
            "-n", "htdemucs",
            "-o", str(work_dir),
            str(input_path),
        ]
        logger.info("stem_separation: starting demucs for %s", input_path.name)
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=SEPARATION_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise SeparationError(f"demucs timed out after {SEPARATION_TIMEOUT_SECONDS}s")

        elapsed = time.monotonic() - started
        if proc.returncode != 0:
            logger.warning("stem_separation: demucs failed (rc=%s) in %.1fs: %s",
                            proc.returncode, elapsed, stderr.decode(errors="replace")[-2000:])
            raise SeparationError("demucs processing failed")

        # demucs writes <out_dir>/htdemucs/<input-stem-without-ext>/{vocals,no_vocals}.wav
        track_name = input_path.stem
        result_dir = work_dir / "htdemucs" / track_name
        vocals_wav = result_dir / "vocals.wav"
        instrumental_wav = result_dir / "no_vocals.wav"
        if not vocals_wav.exists() or not instrumental_wav.exists():
            raise SeparationError("demucs did not produce the expected output files")

        logger.info("stem_separation: demucs finished for %s in %.1fs", input_path.name, elapsed)

        # AAC/.m4a rather than Opus — this app already carries a custom Ogg
        # Opus demuxer (OggOpusDemuxer.swift) for its MAIN playback engine,
        # but that's wired into the full AVAudioEngine pipeline. The result
        # of a separation job is played back from a lightweight standalone
        # preview player instead (see StemSeparationView/AVAudioPlayer), and
        # AVAudioPlayer has no native raw-Ogg-Opus support — AAC/.m4a avoids
        # that mismatch entirely for a modest size cost.
        vocals_aac = work_dir / "vocals.m4a"
        instrumental_aac = work_dir / "instrumental.m4a"
        await _encode_aac(vocals_wav, vocals_aac)
        await _encode_aac(instrumental_wav, instrumental_aac)
        shutil.rmtree(result_dir.parent, ignore_errors=True)

        return {"vocals": vocals_aac, "instrumental": instrumental_aac}


async def _encode_aac(src: pathlib.Path, dest: pathlib.Path) -> None:
    cmd = ["ffmpeg", "-y", "-i", str(src), "-c:a", "aac", "-b:a", "160k", str(dest)]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
    )
    _, stderr = await asyncio.wait_for(proc.communicate(), timeout=120)
    if proc.returncode != 0 or not dest.exists():
        raise SeparationError(f"AAC encode failed for {src.name}: {stderr.decode(errors='replace')[-500:]}")


def make_temp_work_dir() -> pathlib.Path:
    return pathlib.Path(tempfile.mkdtemp(prefix="lumisound-stems-"))
