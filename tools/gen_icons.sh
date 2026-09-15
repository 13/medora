#!/usr/bin/env bash
# Regenerate the raster app icons from assets/icon/medora_pill.svg.
#
# Usage: tools/gen_icons.sh   (run from the repo root)
#
# Outputs:
#   assets/icon/medora_icon_pill.png  - full-bleed padded square, transparent
#                                        background (legacy Android, iOS, web)
#   assets/icon/medora_icon_fg.png    - adaptive foreground: the pill scaled
#                                        to 66% and centred on a transparent
#                                        1024x1024 canvas
#   assets/icon/medora_icon_mono.png  - Android 13+ themed (monochrome) icon:
#                                        same geometry as the foreground with
#                                        every opaque pixel white
#
# After running this, regenerate the platform icon sets with:
#   fvm dart run flutter_launcher_icons
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SVG="assets/icon/medora_pill.svg"
PILL="assets/icon/medora_icon_pill.png"
FG="assets/icon/medora_icon_fg.png"
MONO="assets/icon/medora_icon_mono.png"

rsvg-convert -w 1024 -h 1024 "$SVG" -o "$PILL"

magick "$PILL" -resize 66% -background none -gravity center -extent 1024x1024 "$FG"

magick "$FG" -fill white -colorize 100 "$MONO"

for f in "$PILL" "$FG" "$MONO"; do
  size=$(magick identify -format '%wx%h' "$f")
  echo "$f: $size"
done
