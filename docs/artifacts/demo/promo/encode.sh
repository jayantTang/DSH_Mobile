#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
ffmpeg -hide_banner -loglevel error -y -framerate 24 -i frames/f%05d.png \
  -vf "scale=1280:800:flags=lanczos" -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
  -movflags +faststart out/dsh-mobile-demo.mp4
ffmpeg -hide_banner -loglevel error -y -framerate 24 -i frames/f%05d.png \
  -vf "fps=15,scale=1200:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 out/dsh-mobile-demo.gif
if [ -f frames/f00053.png ]; then
  cp frames/f00053.png out/poster.png
  sips -Z 1600 -s format jpeg -s formatOptions 88 out/poster.png --out out/poster.jpg >/dev/null
fi
ls -lh out
