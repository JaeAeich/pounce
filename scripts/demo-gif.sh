#!/bin/sh
# Renders the README demo GIF (docs/demo.gif) from `pounce snapshot` frames. Needs ffmpeg.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift build -q
.build/debug/Pounce snapshot "$tmp" >/dev/null
d="$tmp/demo"
# Starts on the labels (the still frame GitHub shows), types "shu", clicks, then a beat of the plain app.
cat > "$tmp/list.txt" <<LIST
file '$d/frame-01.png'
duration 1.6
file '$d/frame-02.png'
duration 0.5
file '$d/frame-03.png'
duration 0.5
file '$d/frame-04.png'
duration 1.4
file '$d/frame-05.png'
duration 1.0
file '$d/frame-00.png'
duration 0.6
file '$d/frame-00.png'
LIST
ffmpeg -loglevel error -y -f concat -safe 0 -i "$tmp/list.txt" \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 docs/demo.gif
rm -rf "$tmp"
ls -lh docs/demo.gif
