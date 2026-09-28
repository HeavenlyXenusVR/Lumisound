#!/usr/bin/env bash
# Generates a small demo music library for the screenshot workflow
# (.github/workflows/screenshots-ios.yml).
#
# Every artist, album and title is made up, the audio is synthesized (a
# different tone per track, so nothing reads as a duplicate), and each album
# gets its own gradient cover embedded in the files. Tracks are grouped into
# folders so Home's Quick Access has folder tiles to show.
#
# Usage: make-demo-library.sh <output-dir>
# Needs ffmpeg with libmp3lame. Set FFMPEG to use a specific binary.
set -euo pipefail

OUT="${1:?usage: make-demo-library.sh <output-dir>}"
FFMPEG="${FFMPEG:-ffmpeg}"
mkdir -p "$OUT"
COVERS="$(mktemp -d)"
trap 'rm -rf "$COVERS"' EXIT

# album|artist|genre|year|folder|colour 1|colour 2|gradient type
ALBUMS=(
  "Afterglow Avenue|Neon Harbor|Synthwave|1986|Late Night|0xff3cac|0x2b1055|radial"
  "Paper Moons|Paper Satellites|Indie Pop|2019|Road Trip|0xffb347|0xff5e62|linear"
  "Low Tide Tapes|Quiet Orbit|Lo-Fi|2022|Chill|0x5ee7df|0x3a3d98|linear"
  "Glass Meridian|Glass Meridian|Electronic|2016|Late Night|0x00c6ff|0x0b0b3b|radial"
  "Slow Weather|Sable Coast|Ambient|2008|Chill|0xa8edea|0x355c7d|linear"
  "Static Bloom|Velvet Static|Alt Rock|1997|Road Trip|0xf857a6|0x3b0d2e|radial"
  "Midnight Arcade|Midnight Arcade|R&B|2021|Late Night|0x8e2de2|0x1a0033|linear"
  "Blue Room Sessions|Lumen Drift|Jazz|1974|Focus|0x4facfe|0x0f2027|radial"
)

# album index|title|seconds
TRACKS=(
  "0|Chrome Sunset|224" "0|Harbor Lights|241" "0|Night Drive 86|198"
  "1|Postcards From June|187" "1|Folded Planets|203" "1|Big Sky Radio|176"
  "2|Rain On Tape|152" "2|Window Seat|168" "2|Soft Focus|161"
  "3|Prism Line|236" "3|Refraction|219" "3|Cold Signal|247"
  "4|Fog Horn Lullaby|263" "4|Low Pressure|281"
  "5|Feedback Garden|212" "5|Paper Cuts|195" "5|Overpass|229"
  "6|Neon Confession|207" "6|After Hours|221" "6|Slow Motion Heart|199"
  "7|Blue Room|284" "7|Late Set|256" "7|Brushes|238"
  "1|Highway Hymn|214"
)

# Each cover: a two-colour gradient, a glowing disc in the lighter colour
# (placed differently per album) and a little grain.
for i in "${!ALBUMS[@]}"; do
  IFS='|' read -r _ _ _ _ _ c0 c1 kind <<<"${ALBUMS[$i]}"
  if [ "$kind" = radial ]; then
    gradient="gradients=s=600x600:c0=${c0}:c1=${c1}:x0=300:y0=260:x1=660:y1=660:type=radial:d=1:speed=0.0001"
  else
    gradient="gradients=s=600x600:c0=${c0}:c1=${c1}:x0=0:y0=0:x1=600:y1=600:d=1:speed=0.0001"
  fi
  cx=$((150 + (i * 97) % 300)); cy=$((170 + (i * 61) % 260)); r=$((90 + (i * 23) % 70))
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$gradient" \
    -f lavfi -i "color=c=${c0}:s=600x600:d=1,format=rgba,geq=r='min(255,r(X,Y)+70)':g='min(255,g(X,Y)+70)':b='min(255,b(X,Y)+70)':a='255*clip((${r}+14-hypot(X-${cx},Y-${cy}))/28,0,1)*0.85'" \
    -filter_complex "[0][1]overlay=format=auto,vignette=PI/6,noise=alls=5:allf=u" \
    -frames:v 1 -q:v 3 "$COVERS/$i.jpg"
done

n=0
track_numbers=()  # indexed by album; bash 3.2 (macOS) has no associative arrays
for entry in "${TRACKS[@]}"; do
  IFS='|' read -r album_index title seconds <<<"$entry"
  IFS='|' read -r album artist genre year folder _ _ _ <<<"${ALBUMS[$album_index]}"
  track_numbers[$album_index]=$(( ${track_numbers[$album_index]:-0} + 1 ))
  n=$((n + 1))

  # A soft two-note pad with a slow pulse; pitch and pulse differ per track.
  base=$((110 + n * 13))
  fifth=$((base * 3 / 2))
  pulse="0.$((n % 7 + 2))"
  mkdir -p "$OUT/$folder"
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.18*(sin(2*PI*${base}*t)+0.6*sin(2*PI*${fifth}*t))*(0.65+0.35*sin(2*PI*${pulse}*t)):s=44100:d=${seconds}" \
    -i "$COVERS/$album_index.jpg" \
    -map 0:a -map 1:v -c:a libmp3lame -b:a 96k -c:v copy \
    -id3v2_version 3 \
    -metadata title="$title" -metadata artist="$artist" -metadata album_artist="$artist" \
    -metadata album="$album" -metadata genre="$genre" -metadata date="$year" \
    -metadata track="${track_numbers[$album_index]}" \
    -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
    "$OUT/$folder/$artist - $title.mp3"
done

echo "Wrote $n tracks to $OUT"
