#!/usr/bin/env bash
# Saturday Grid TikTok builder: slides + approved music bed -> 1080x1920 MP4.
# Usage: make_video.sh OUTPUT.mp4 SECONDS_PER_SLIDE IMAGE1 [IMAGE2 ...]
#   Square:  make_video.sh out.mp4 5 square.jpg              (1 image, 5s)
#   Morning: make_video.sh out.mp4 2.5 s1.jpg s2.jpg s3.jpg  (3 images, 7.5s)
# Env: BED=path to bed audio (default /workspace/sg-audio/bed.mp3)
# Images may be JPG or PNG (any size; letterboxed to 1080x1920 on black).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  sed -n '3,7p' "$0" >&2; exit 2
fi
OUT=$1; SECS=$2; shift 2
BED=${BED:-/workspace/sg-audio/bed.mp3}
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
[ -f "$BED" ] || { echo "bed audio not found: $BED" >&2; exit 1; }
for img in "$@"; do [ -f "$img" ] || { echo "image not found: $img" >&2; exit 1; }; done
awk -v s="$SECS" 'BEGIN{exit !(s+0>0)}' || { echo "SECONDS_PER_SLIDE must be > 0" >&2; exit 2; }

N=$#
TOTAL=$(awk -v n="$N" -v s="$SECS" 'BEGIN{printf "%.3f", n*s}')
FADE_OUT_START=$(awk -v t="$TOTAL" 'BEGIN{v=t-0.6; if(v<0)v=0; printf "%.3f", v}')

inputs=(); filt=""; concat=""
i=0
for img in "$@"; do
  inputs+=(-loop 1 -framerate 30 -t "$SECS" -i "$img")
  filt+="[$i:v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p,fps=30,trim=duration=$SECS,setpts=PTS-STARTPTS[v$i];"
  concat+="[v$i]"
  i=$((i+1))
done
filt+="${concat}concat=n=$N:v=1:a=0,format=yuv420p[v];"
# Audio: bed from 0s, fades, then two-pass linear loudnorm to -17 LUFS (fades preserved).
APRE="atrim=0:$TOTAL,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.4,afade=t=out:st=$FADE_OUT_START:d=0.6"
MEAS=$(ffmpeg -hide_banner -nostats -i "$BED" -af "$APRE,loudnorm=I=-17:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { printf '%s' "$MEAS" | sed -n "s/.*\"$1\" : \"\([^\"]*\)\".*/\1/p"; }
LN="loudnorm=I=-17:TP=-1.5:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp):measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true"
[ -n "$(get input_i)" ] || LN="loudnorm=I=-17:TP=-1.5:LRA=11"
filt+="[$N:a]$APRE,$LN,aresample=44100[a]"

ffmpeg -hide_banner -loglevel error -y "${inputs[@]}" -i "$BED" \
  -filter_complex "$filt" -map "[v]" -map "[a]" \
  -c:v libx264 -profile:v high -preset medium -crf 20 -pix_fmt yuv420p -color_range tv -r 30 \
  -c:a aac -b:a 160k -ar 44100 -ac 2 \
  -t "$TOTAL" -movflags +faststart "$OUT"

echo "Wrote $OUT (${N} slide(s) x ${SECS}s = ${TOTAL}s)"
