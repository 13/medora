#!/usr/bin/env bash
# tools/phone_check/make_test_image.sh
# Renders a synthetic supplement label with a valid EAN-13 barcode, for
# tools/phone_check/run.sh to push to the phone's gallery. Writes
# tools/phone_check/out/test-label.png. Requires ImageMagick's `magick`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT/out"
OUT="$OUT_DIR/test-label.png"
EAN="8057737141836"

command -v magick >/dev/null 2>&1 || {
  echo "make_test_image.sh: ImageMagick 'magick' not found (install imagemagick)" >&2
  exit 1
}

mkdir -p "$OUT_DIR"

# EAN-13 bar encoding tables (7 bits per digit), indexed 0-9.
L=(0001101 0011001 0010011 0111101 0100011 0110001 0101111 0111011 0110111 0001011)
G=(0100111 0110011 0011011 0100001 0011101 0111001 0001011 0001001 0010001 0010111)
R=(1110010 1100110 1101100 1000010 1011100 1001110 1010000 1000100 1001000 1000000)
# Left-hand L/G parity pattern for digits 2-7, indexed by the first digit.
PARITY=(LLLLLL LLGLGG LLGGLG LLGGGL LGLLGG LGGLLG LGGGLL LGLGLG LGLGGL LGGLGL)

first="${EAN:0:1}"
left="${EAN:1:6}"
right="${EAN:7:6}"
pattern="${PARITY[$first]}"

bits="101" # start guard
for i in 0 1 2 3 4 5; do
  d="${left:$i:1}"
  p="${pattern:$i:1}"
  if [ "$p" = "L" ]; then
    bits+="${L[$d]}"
  else
    bits+="${G[$d]}"
  fi
done
bits+="01010" # middle guard
for i in 0 1 2 3 4 5; do
  d="${right:$i:1}"
  bits+="${R[$d]}"
done
bits+="101" # end guard

BAR_X=100
BAR_Y=520
BAR_W=6
BAR_H=220

args=(
  -size 1600x900 xc:white
  -gravity NorthWest
  -pointsize 40 -fill black
  -annotate +100+80 "Integratore alimentare"
  -annotate +100+160 "COD MINSAN: 107018"
  -annotate +100+240 "Lotto 4R5T21"
  -annotate +100+320 "SCAD. 12/2027"
)

x="$BAR_X"
for ((i = 0; i < ${#bits}; i++)); do
  if [ "${bits:$i:1}" = "1" ]; then
    args+=(-draw "rectangle $x,$BAR_Y $((x + BAR_W - 1)),$((BAR_Y + BAR_H))")
  fi
  x=$((x + BAR_W))
done

args+=(-pointsize 30 -annotate +100+780 "$EAN")
args+=("$OUT")

magick "${args[@]}"
echo "wrote $OUT"
