#!/bin/bash
# Renders the 1080x1350 phone cut of the site walkthrough.
#
# The cut reuses the published desktop cut's sound and captions, so it costs
# no narration or music call: the board is rendered silent (no narration, no
# music; every scene then runs its min_ms, the same 44 s timeline), and the
# frames are encoded and muxed with the desktop mp4's AAC track and mov_text
# captions. The silent board is assembled here rather than by
# walkthrough_render.rb, whose loudnorm pass rejects an all-silent bus.
#
#   walkthrough/site-self-mobile/tools/render.sh <desktop.mp4> <out dir>
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
desktop=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(mkdir -p "$2" && cd "$2" && pwd)
build=$out/build/site-self-mobile
img='jrottenberg/ffmpeg:7.1.2-ubuntu2404@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d'

python3 "$here/tools/silent_board.py" "$here" "$build"
ruby ~/.claude/cf/bin/walkthrough_storyboard.rb validate "$build/storyboard.json" --fix
# Captures every scene; the final ffmpeg pass fails on the silent bus, by design here.
ruby ~/.claude/cf/bin/walkthrough_render.rb "$build" --draft --no-roast || true

python3 - "$build" <<'PY'
import json, sys
b = sys.argv[1]
with open(f"{b}/frames.txt", "w") as f:
    for s in json.load(open(f"{b}/manifest.json"))["scenes"]:
        for i in range(1, s["frames"] + 1):
            f.write(f"file '/b/.cache/frames/{s['frames_key']}/{i:06d}.png'\nduration 0.0333333\n")
PY

docker run --rm --network none -v "$build":/b -v "$(dirname "$desktop")":/p:ro -v "$out":/o "$img" \
  -y -hide_banner -loglevel error -f concat -safe 0 -i /b/frames.txt -i "/p/$(basename "$desktop")" \
  -map 0:v -map 1:a -map '1:s?' -c:v libx264 -preset slow -crf 26 -profile:v high -pix_fmt yuv420p -r 30 \
  -tune stillimage -c:a copy -c:s copy -t 44 -movflags +faststart /o/walkthrough-mobile.mp4
# Poster: the recorded verdict, scaled to stay under the 60 KB poster guard.
docker run --rm --network none -v "$out":/o "$img" -y -hide_banner -loglevel error -ss 36 \
  -i /o/walkthrough-mobile.mp4 -frames:v 1 -vf scale=864:1080:flags=lanczos -q:v 6 /o/poster-mobile.jpg
echo "$out/walkthrough-mobile.mp4"
