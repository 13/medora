#!/usr/bin/env bash
# tools/phone_check/run.sh <adb-serial>
# Drives one attached phone through the scanner flow and captures
# screenshots plus [scan] log lines. See README.md. Never run in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SERIAL="${1:-}"
PKG="${MEDORA_PACKAGE:-com.medora.medora}"

if [ -z "$SERIAL" ]; then
  echo "usage: tools/phone_check/run.sh <adb-serial>   (adb devices -l)" >&2
  exit 2
fi
case "$SERIAL" in
emulator-*)
  echo "refusing to run against an emulator ($SERIAL): ML Kit and the camera need a real device" >&2
  exit 1
  ;;
esac
adb devices | awk '{print $1}' | grep -qx "$SERIAL" || {
  echo "device $SERIAL is not attached" >&2
  exit 1
}

OUT="$ROOT/out/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

# Echo every step to the terminal and into run.log.
exec > >(tee -a "$OUT/run.log") 2>&1

A="adb -s $SERIAL"

echo "== phone check: $SERIAL, package $PKG, output $OUT =="

# --- tap points, as a percentage of the screen size (see README) ---------
# Home -> open the scanner (AppBar scan icon).
TAP_SCANNER_X="${MEDORA_TAP_SCANNER_X:-90}"
TAP_SCANNER_Y="${MEDORA_TAP_SCANNER_Y:-8}"
# Scanner screen -> open the gallery (AppBar photo_library icon).
TAP_GALLERY_X="${MEDORA_TAP_GALLERY_X:-85}"
TAP_GALLERY_Y="${MEDORA_TAP_GALLERY_Y:-8}"
# System photo picker -> the newest (first) thumbnail.
TAP_PHOTO_X="${MEDORA_TAP_PHOTO_X:-15}"
TAP_PHOTO_Y="${MEDORA_TAP_PHOTO_Y:-20}"
# Review screen -> the supplement (COD MINSAN) candidate row.
TAP_ROW_X="${MEDORA_TAP_ROW_X:-50}"
TAP_ROW_Y="${MEDORA_TAP_ROW_Y:-55}"
# Primary button on a centered confirm dialog (register download prompt,
# then the "did you mean" confirmation) — same spot for both.
TAP_CONFIRM_X="${MEDORA_TAP_CONFIRM_X:-74}"
TAP_CONFIRM_Y="${MEDORA_TAP_CONFIRM_Y:-58}"

read -r SCREEN_W SCREEN_H < <(
  $A shell wm size | sed -n 's/.*: *\([0-9]*\)x\([0-9]*\).*/\1 \2/p'
)
echo "screen size: ${SCREEN_W}x${SCREEN_H}"

tap_pct() { # tap_pct <x-percent> <y-percent>
  local x=$((SCREEN_W * $1 / 100))
  local y=$((SCREEN_H * $2 / 100))
  $A shell input tap "$x" "$y"
  echo "tap $1% $2% -> $x,$y"
}

shot() { # shot <filename>
  $A exec-out screencap -p >"$OUT/$1"
  echo "screenshot $1"
}

echo "-- generating the test label image --"
TEST_IMAGE="$ROOT/out/test-label.png"
if [ ! -f "$TEST_IMAGE" ]; then
  "$ROOT/make_test_image.sh"
fi

echo "-- pushing the test label into the phone's gallery --"
$A push "$TEST_IMAGE" /sdcard/Pictures/medora-test-label.png
$A shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/Pictures/medora-test-label.png >/dev/null

echo "-- granting camera + notification permissions (skip the runtime prompt) --"
$A shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
$A shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

echo "-- starting [scan] log capture --"
$A logcat -c
$A logcat -v time | grep --line-buffered '\[scan\]' >"$OUT/scan.log" &
LOGCAT_PID=$!
cleanup() { kill "$LOGCAT_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "-- launching $PKG --"
$A shell am force-stop "$PKG"
$A shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 2
shot 01-home.png

echo "-- opening the scanner --"
tap_pct "$TAP_SCANNER_X" "$TAP_SCANNER_Y"
sleep 2
shot 02-scanner.png

echo "-- opening the gallery --"
tap_pct "$TAP_GALLERY_X" "$TAP_GALLERY_Y"
sleep 2
echo "-- picking the newest photo --"
tap_pct "$TAP_PHOTO_X" "$TAP_PHOTO_Y"
sleep 2
shot 03-review.png

echo "-- selecting the supplement candidate row --"
tap_pct "$TAP_ROW_X" "$TAP_ROW_Y"
sleep 2
echo "-- confirming the register download prompt, if shown --"
tap_pct "$TAP_CONFIRM_X" "$TAP_CONFIRM_Y"
sleep 2
echo "-- confirming the 'did you mean' dialog, if shown --"
tap_pct "$TAP_CONFIRM_X" "$TAP_CONFIRM_Y"
sleep 2
shot 04-selected.png

cleanup
trap - EXIT
sleep 1 # let the last buffered log lines land

CANDIDATE_COUNT="$(grep -c '\[scan\] candidate:' "$OUT/scan.log" || true)"
echo "== output: $OUT =="
echo "[scan] candidate: lines: $CANDIDATE_COUNT"

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "no '[scan] candidate:' line in scan.log — the scan flow likely failed or SCAN_DEBUG=true was not set at build time" >&2
  exit 1
fi
