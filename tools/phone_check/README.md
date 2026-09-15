# Phone check: a repeatable on-device scanner check

`tools/phone_check/run.sh` drives one attached Android phone through
Medora's real photo-scanner flow — Home → scanner → gallery → newest photo
→ review → select the supplement candidate → register download prompt →
confirm dialog — and captures screenshots plus the scanner's own `[scan]`
debug log lines. It exists to catch regressions in the scanner that unit
and widget tests cannot: real ML Kit models, a real camera stack, a real
Android photo picker.

**This script is not part of CI and must never be added to a GitHub
Actions workflow (or any other automated pipeline).** It needs a physical
device with USB debugging enabled and takes control of its screen; there
is no way to run it headlessly.

## What it proves

A single run confirms, on real hardware, that:

- the app launches and the scanner screen opens;
- picking a photo from the gallery runs OCR and barcode decoding and
  reaches the review screen;
- at least one `[scan] candidate:` was recognised (the OCR/candidate
  pipeline ran end to end, not just "the app didn't crash");
- tapping a supplement candidate resolves it (register download prompt,
  then the confirm dialog), the same path a user takes.

It is a smoke check, not a correctness oracle — read `scan.log` and the
screenshots yourself to judge whether what was recognised is *right*.

## Prerequisites

- `adb` on `PATH`, with USB debugging enabled on the phone and the phone
  authorised for this machine.
- ImageMagick's `magick` (used by `make_test_image.sh` to render the test
  label; `sudo apt install imagemagick` or equivalent).
- A debug build of Medora installed on the phone, built with scanner
  debug logging on:

  ```bash
  fvm flutter build apk --debug --dart-define=SCAN_DEBUG=true
  adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
  ```

  Without `--dart-define=SCAN_DEBUG=true` the app never prints `[scan]`
  lines ([scan_debug.dart](../../lib/services/scan_debug.dart)) and the
  run will fail its own `[scan] candidate:` check even if the scan itself
  worked.

## Finding the serial

```bash
adb devices -l
```

The **serial is mandatory** — `run.sh` refuses to run without one, and
refuses any serial starting with `emulator-`. ML Kit's on-device models
and the camera stack behave differently on the emulator's virtual camera,
so an emulator run proves nothing about the real device experience; this
repo's checked-out user also keeps a separate emulator attached
alongside the test phone, so an implicit default device would be unsafe.

## Running it

```bash
tools/phone_check/run.sh RZCXA1ZEXJE
```

(`RZCXA1ZEXJE` is the team's Samsung SM-A346B test phone; substitute your
own serial from `adb devices -l`.)

The script:

1. renders `tools/phone_check/out/test-label.png` with
   `make_test_image.sh` if it isn't already there (a synthetic
   supplement label: `Integratore alimentare`, `COD MINSAN: 107018`,
   `Lotto 4R5T21`, `SCAD. 12/2027`, and a real, checksum-valid EAN-13
   barcode `8057737141836` drawn as bars plus digits);
2. pushes it to the phone's gallery (`/sdcard/Pictures/medora-test-label.png`)
   and tells the media scanner about it;
3. pre-grants the camera and notification runtime permissions, so the
   permission dialog doesn't block the flow;
4. starts capturing `[scan]` logcat lines into `scan.log`;
5. force-stops and relaunches the app, then taps through Home → scanner
   → gallery → the newest photo → review → the supplement candidate row
   → the register download prompt → the confirm dialog, screenshotting
   at each stage;
6. stops the log capture and reports how many `[scan] candidate:` lines
   were seen.

## Output

Each run creates a fresh, timestamped directory:

```
tools/phone_check/out/<UTC timestamp>/
  01-home.png       # Home screen, right after launch
  02-scanner.png     # Scanner screen, before picking a photo
  03-review.png       # Review screen, after OCR ran on the picked photo
  04-selected.png      # After tapping the supplement row and confirming
  scan.log             # every "[scan] ..." logcat line captured during the run
  run.log               # every step the script took, echoed as it ran
```

`tools/phone_check/out/` (including `test-label.png`) is git-ignored —
each run's evidence is local, disposable, and never committed.

The run exits non-zero if any `adb` call fails, or if `scan.log` ends up
with no `[scan] candidate:` line — the strongest single signal that the
scan pipeline did not run.

## Reading `scan.log`

Lines come straight from [scan_debug.dart](../../lib/services/scan_debug.dart)
and [barcode_adapter.dart](../../lib/services/barcode_adapter.dart):

- `[scan] line: <text> @ <left>,<top> <width>x<height>` — one per
  recognised OCR text line, followed by `[scan]   element: ...` for each
  word/token inside it.
- `[scan] barcode: <format> <raw value> @ <box>` — one per decoded
  barcode (e.g. the EAN-13 on the test label).
- `[scan] candidate: <kind> <code> (<source text>) @ <box>` — one per
  candidate the scanner's code-candidate logic produced, the thing the
  review screen actually renders as a tappable row. The final `run.log`
  summary counts these lines.

## Tuning the tap coordinates for a different phone

The script drives the UI with `adb shell input tap`, computed as a
percentage of `adb shell wm size`, not fixed pixels — so it survives
different resolutions but not different layouts. If a screenshot shows a
tap landed on the wrong element, override the offending step with an
environment variable and re-run:

| Step | Variables (defaults, `%` of screen width/height) |
|---|---|
| Home → open the scanner | `MEDORA_TAP_SCANNER_X` (90), `MEDORA_TAP_SCANNER_Y` (8) |
| Scanner → open the gallery | `MEDORA_TAP_GALLERY_X` (85), `MEDORA_TAP_GALLERY_Y` (8) |
| Gallery picker → newest photo | `MEDORA_TAP_PHOTO_X` (15), `MEDORA_TAP_PHOTO_Y` (20) |
| Review → the supplement row | `MEDORA_TAP_ROW_X` (50), `MEDORA_TAP_ROW_Y` (55) |
| Register-download / "did you mean" confirm | `MEDORA_TAP_CONFIRM_X` (74), `MEDORA_TAP_CONFIRM_Y` (58) |

For example, to nudge the supplement-row tap down a bit:

```bash
MEDORA_TAP_ROW_Y=62 tools/phone_check/run.sh RZCXA1ZEXJE
```

`MEDORA_PACKAGE` overrides the app id if you're checking a build under a
different application id (default `com.medora.medora`).

Once a phone's coordinates are dialed in, export them in your shell
profile (or wrap the invocation in a small local script — not committed,
since they're specific to one phone's screen).
