FROM python:3.12-slim

# atomicparsley is required for yt-dlp's --embed-thumbnail to work on M4A —
# ffmpeg alone can embed thumbnails into mp3/opus/etc, but not M4A/MP4 containers.
# aria2 (aria2c) is used as yt-dlp's external downloader for multi-connection,
# segmented downloads — substantially faster than the built-in downloader.
# libchromaprint-tools provides `fpcalc` for acoustic fingerprinting (used by
# the /user/library/acoustic-duplicates endpoint to catch true duplicates whose
# metadata differs). mesa-va-drivers provides the actual VAAPI hardware driver
# backend (radeonsi, for the host's AMD iGPU) — ffmpeg's Debian package links
# against libva already, but without this driver package `-vaapi_device` has
# nothing to load and every hardware-encode attempt fails (safe: main.py's
# motion-artwork extraction falls back to software libx264 automatically).
# libsndfile1 is the system library torchaudio's `soundfile` backend links
# against (see the stem-separation torch/torchaudio pin below) — without it,
# torchaudio.save() has no backend at all ("Couldn't find appropriate
# backend to handle uri ... and format None"), even with the matching Python
# package installed.
RUN apt-get update && apt-get install -y ffmpeg curl unzip atomicparsley aria2 libchromaprint-tools mesa-va-drivers libsndfile1 && rm -rf /var/lib/apt/lists/*

# yt-dlp now needs a JS runtime to solve YouTube's player/signature challenge
# (EJS) — without one, extraction fails for most videos with "This video is
# not available". Deno is the runtime yt-dlp enables by default.
# `curl | sh` alone silently ships a broken image on any network hiccup: a
# failed curl still leaves `sh` reading an empty pipe, which exits 0, so the
# RUN step "succeeds" having installed nothing. The trailing `test -x` makes
# a failed install fail the build instead of shipping a JS-runtime-less image.
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh \
    && test -x /usr/local/bin/deno
ENV PATH="/usr/local/bin:${PATH}"

# Install yt-dlp pinned version via pip — kept current; YouTube changes its
# player/signature internals often enough that a stale yt-dlp is the #1 cause
# of "Unable to find stream URL" extraction failures.
# yt-dlp-ejs bundles the JS challenge solver script yt-dlp now requires for
# YouTube extraction, so Deno can run it without fetching remote components.
# bgutil-ytdlp-pot-provider is the CLIENT half of the proof-of-origin-token
# plugin (retrieves tokens from the bgutil-pot-provider HTTP server started
# alongside this container — see docker-compose.yml) — a valid PO token
# meaningfully speeds up/stabilizes YouTube extraction, which otherwise
# routinely takes 70-100+ seconds per video without one. No-ops harmlessly if
# YTDLP_POT_PROVIDER_URL is unset (yt-dlp just extracts without a token, as
# before this was added).
RUN pip install --no-cache-dir yt-dlp==2026.8.19 yt-dlp-ejs bgutil-ytdlp-pot-provider

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Demucs (real source separation for the stem-separation feature — see
# stem_separation.py) needs PyTorch, which is deliberately NOT in
# requirements.txt the way faster-whisper's lighter ctranslate2 backend is —
# there's no comparable non-torch separation model with similar quality.
# Installed from PyTorch's own CPU-only wheel index so this doesn't pull in
# CUDA runtime libraries (multiple GB, entirely dead weight — this host has
# no GPU). Still a real image-size and build-time cost; that's the accepted
# tradeoff for actual separation quality over a cheaper EQ-notch fake.
#
# torch/torchaudio are PINNED, not left to float to latest — demucs==4.0.1
# (2023) calls the legacy `torchaudio.save()` path unconditionally. Recent
# torchaudio releases dropped that implementation's sox/soundfile backend in
# favor of a separate `torchcodec` package that this image never installed,
# so every separation job ran the full 1-4 minute model pass and then failed
# at the very last step writing the output WAV ("ModuleNotFoundError: No
# module named 'torchcodec'") — a 100% failure rate, confirmed by
# reproducing the exact command inside the running container. 2.3.1 is the
# newest line confirmed (by actually running torchaudio.save() against it,
# not just importing it) to still carry that legacy backend — anything
# older doesn't understand `numpy==2.3.3` (pinned in requirements.txt, which
# installs before this), and silently crashes at inference time instead of
# at import ("RuntimeError: Numpy is not available") despite looking fine on
# import. The `soundfile` package (plus `libsndfile1` above) is what
# actually backs torchaudio.save() here — without it this is the same
# "couldn't find appropriate backend" failure by a different route.
RUN pip install --no-cache-dir torch==2.3.1 torchaudio==2.3.1 --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir soundfile \
    && pip install --no-cache-dir demucs==4.0.1

COPY . .

# Bake the htdemucs model weights into the image, same reasoning as the
# Whisper bake below — the first real request shouldn't pay a ~80 MB
# download, and shouldn't silently depend on Meta's model host being
# reachable at exactly that moment.
#
# TORCH_HOME must be a persisted ENV, not just set inside the RUN step's own
# python process — that only affected the bake script itself. Without this,
# the running container never saw TORCH_HOME at all, so `get_model()` always
# fell back to re-downloading into `/root/.cache/torch/hub/checkpoints` on
# first real use, defeating the whole point of baking it in.
ENV LUMISOUND_DEMUCS_CACHE=/app/cache/demucs
ENV TORCH_HOME=/app/cache/demucs
RUN python -c "\
from demucs.pretrained import get_model; \
get_model('htdemucs'); \
print('demucs model htdemucs cached')"

# Bake the Whisper weights into the image rather than downloading them on first
# use. The lazy path in lyrics_whisper._load_model works, but it would make the
# very first transcription request pay a ~150 MB download, and would leave local
# transcription silently dependent on Hugging Face being reachable at exactly
# that moment. Kept in the same directory lyrics_whisper defaults to.
ENV LUMISOUND_WHISPER_CACHE=/app/cache/whisper
RUN python -c "\
from faster_whisper import WhisperModel; \
import os; \
m = os.environ.get('LUMISOUND_WHISPER_MODEL', 'base'); \
WhisperModel(m, device='cpu', compute_type='int8', download_root='/app/cache/whisper'); \
print('whisper model', m, 'cached')"

ENV PYTHONUNBUFFERED=1

EXPOSE 8002

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8002"]
