# AIC scanner: take a photo, then choose the code — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the continuous live-stream OCR (a growing, jumping list of text lines) with a deliberate flow: the user takes one photo (or picks one from the gallery), Medora recognises text on that still image, shows the photo with every detected code highlighted, and the user taps the code to use — AIC codes first.

**Architecture:** The scanner screen becomes a three-state flow `capture → recognizing → review`. Capture shows the camera preview with a shutter button, torch, gallery import and manual entry; no image stream runs. The still image goes to ML Kit via `InputImage.fromFilePath`. A pure function turns recognised lines into ranked `CodeCandidate`s (unit-tested without ML Kit). A new `ScanReviewView` widget renders the photo with tappable numbered overlays plus a list of the same candidates; selecting one feeds the existing `_handleCode` (return-only pop, or AIFA lookup → result picker → Add Medication). Captured temp files are deleted on retake and dispose.

**Tech Stack:** Flutter 3.44.6 (`fvm`, Dart 3.12), `camera` ^0.12 (`takePicture`, `setFocusMode`), `google_mlkit_text_recognition` 0.17.1 (`TextBlock/TextLine/TextElement.boundingBox`), `image_picker` ^1.1 (present), flutter_riverpod 3, go_router 18.

## Global Constraints

- Flutter via `fvm` (always `fvm dart format`, never bare `dart`); curated lints + `dart format --set-exit-if-changed .`; `fvm flutter analyze --fatal-infos` clean; `fvm flutter test` green (baseline 425 + 2 skipped); guards `theme_sweep`, `l10n_sweep`, `clock_sweep`; 6 goldens unchanged.
- Package imports only; theme tokens only (the existing scrim colours with `// scrim` comments are the allowed exception pattern); every string via ARB en/de/it + `fvm flutter gen-l10n`, commit generated, `untranslated.txt` = `{}`.
- Behaviour kept: route `/scanner`, `?returnOnly=true` returns the chosen raw code to the caller (Add Medication barcode field); without it the AIFA lookup, multi-result picker and push to Add Medication stay exactly as today; manual entry stays.
- AIC detection stays `BarcodeLookupDatasource.extractCodes` / `cleanCode` (leading letter optional, 6–9 digits); do not change the AIFA search.
- Privacy: photos taken by the scanner are temporary files, deleted on retake, on selection and in `dispose`; gallery picks are never deleted.
- Commits end with the two attribution lines from the session's system reminder.

---

## File structure

| Path | Responsibility |
|---|---|
| `lib/services/code_candidates.dart` (new) | `OcrLine`, `OcrElement`, `CodeCandidate`, `findCodeCandidates(List<OcrLine>)` — pure, no ML Kit import. |
| `lib/services/ocr_adapter.dart` (new) | `List<OcrLine> ocrLinesFrom(RecognizedText)` — the only ML Kit ↔ domain mapping. |
| `lib/presentation/screens/scanner/scan_review_view.dart` (new) | Photo with numbered overlays + candidate list; retake / manual entry. |
| `lib/presentation/screens/scanner/barcode_scanner_screen.dart` | Capture/recognizing/review state machine; camera, gallery, OCR call; reuses `_handleCode`, `_showResultPicker`, `_selectResult`, `_showManualEntryDialog`. |
| `test/services/code_candidates_test.dart`, `test/presentation/screens/scan_review_view_test.dart` | Tests. |

---

### Task 1: Candidate extraction (pure) + review view

**Interfaces:**
```dart
// lib/services/code_candidates.dart
class OcrElement { const OcrElement(this.text, this.box); final String text; final Rect box; }
class OcrLine { const OcrLine(this.text, this.box, [this.elements = const []]); final String text; final Rect box; final List<OcrElement> elements; }
enum CodeKind { aic, other }
class CodeCandidate {
  const CodeCandidate({required this.code, required this.kind, required this.sourceText, required this.box});
  final String code;       // AIC: cleaned digits (cleanCode); other: alphanumerics without spaces
  final CodeKind kind;
  final String sourceText; // the OCR line it came from
  final Rect box;          // image-pixel rect: the element containing the code if one does, else the line
}
/// AIC codes first (9-digit before shorter, then top-to-bottom, left-to-right),
/// then other number-like tokens (>= 6 chars with >= 4 digits, e.g. lot/batch),
/// deduplicated by code, at most [limit].
List<CodeCandidate> findCodeCandidates(List<OcrLine> lines, {int limit = 20});
```
```dart
// lib/presentation/screens/scanner/scan_review_view.dart
class ScanReviewView extends StatelessWidget {
  const ScanReviewView({super.key, required this.image, required this.imageSize, required this.candidates,
    required this.onSelected, required this.onRetake, required this.onManualEntry, this.busy = false});
  final ImageProvider image; final Size imageSize; final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate> onSelected; final VoidCallback onRetake; final VoidCallback onManualEntry; final bool busy;
}
```

- [ ] **Step 1: Unit tests** `test/services/code_candidates_test.dart`:
  - `A023834118` on a line → one AIC candidate `023834118`, box = the element's box when elements are given.
  - Mixed lines `Lotto 4R5T21`, `AIC n. 034567891`, `Scad. 03/2027`, `EAN 8001234567890` → AIC `034567891` first; `other` contains `4R5T21` and `8001234567890`; `03/2027` excluded (fewer than 6 alphanumerics).
  - The same AIC on two lines → one candidate (first occurrence's box).
  - 9-digit AIC ranks before a 6-digit AIC regardless of position; equal lengths ordered by `box.top`, then `box.left`.
  - Empty input → empty; `limit` respected.
- [ ] **Step 2: Implement** `code_candidates.dart` (use `BarcodeLookupDatasource.extractCodes` for AIC matches; an `other` token must not duplicate an AIC code or be a substring of one) and `ocr_adapter.dart` (`TextLine.boundingBox`, `TextElement` text/boundingBox).
- [ ] **Step 3: Widget tests** `test/presentation/screens/scan_review_view_test.dart` (use `MemoryImage` of a 1×1 PNG and `imageSize: Size(1000, 1000)`; `pumpMedoraApp` with locale `de` where text is asserted):
  - Two AIC + one other candidate → list shows section headers `scanAicCodes` then `scanOtherNumbers`, rows numbered `1`, `2`, `3` in that order; overlay renders three tappable markers with the same numbers.
  - Tapping row `1` and tapping overlay marker `2` each call `onSelected` with the right candidate.
  - `busy: true` disables taps.
  - No candidates → `scanNoCodeFound` text plus buttons `scanRetake` and `enterBarcodeManually`, both wired.
  - At 360×800 no overflow.
- [ ] **Step 4: Implement** `ScanReviewView`: top: `AspectRatio(imageSize)` → `InteractiveViewer` → `Stack(Image(fit: contain) + LayoutBuilder overlay)`, marker rects scaled from image pixels to the laid-out size; AIC markers `primaryContainer` fill + `primary` border, others `outline` border; each marker a numbered chip at the rect's top-left, min 40 dp tap target. Bottom: `ListView` with the two sections, rows `ListTile(leading: number badge, title: code, subtitle: sourceText, trailing: chevron)`; AIC rows use `primaryContainer`. Footer row: `OutlinedButton.icon(camera, scanRetake)` + `TextButton.icon(keyboard, enterBarcodeManually)`.
- [ ] **Step 5: ARB** (en / de / it): `scanTakePhoto` "Take photo" / "Foto aufnehmen" / "Scatta foto"; `scanFromGallery` "Choose from gallery" / "Aus Galerie wählen" / "Scegli dalla galleria"; `scanRetake` "Retake" / "Neues Foto" / "Rifai foto"; `scanRecognizing` "Reading text…" / "Text wird erkannt…" / "Riconoscimento del testo…"; `scanChooseCode` "Tap the code to use" / "Tippe auf den gewünschten Code" / "Tocca il codice da usare"; `scanAicCodes` "AIC codes" / "AIC-Codes" / "Codici AIC"; `scanOtherNumbers` "Other numbers" / "Weitere Nummern" / "Altri numeri"; `scanNoCodeFound` "No code found. Retake the photo closer, or type the code." / "Kein Code erkannt. Fotografiere näher oder tippe den Code ein." / "Nessun codice trovato. Scatta più da vicino o inserisci il codice."; `scanCaptureHint` "Photograph the pack so the AIC code is sharp" / "Fotografiere die Packung so, dass der AIC-Code scharf ist" / "Fotografa la confezione con il codice AIC ben leggibile". Remove `ocrDetectedCodes`, `ocrScanning`, `pointCameraAtBarcode` only if unreferenced after Task 2 (grep).
- [ ] **Step 6: Verify** gates. **Commit** — `feat(scanner): rank OCR code candidates and review them on the photo`

---

### Amendment (2026-09-15): supplement and EAN codes

The user photographed a food-supplement label (`COD MINSAN: 107018`, EAN-13 printed as `8 057737 141836`). Supplements are not in the AIFA medicines database, and the old `extractCodes` reported `107018` as an AIC and cut the EAN to `805773714`. Task 1 therefore uses a wider candidate model (no lookup for the new kinds in this task):

- `enum CodeKind { aic, supplement, ean, other }`.
- `supplement`: a 6–9 digit number on a line (or the line right after a line) whose text carries a Ministry-code label, case-insensitive and tolerant of OCR spacing/punctuation: `MINSAN`, `MIN SAN`, `COD. MIN`, `COD MIN`, `CODICE MINISTERIALE`, `CODICE NOTIFICA`, `NOTIFICA N`. Such numbers are not also reported as `aic`; a letter-prefixed 9-digit code without such a label stays `aic`.
- `ean`: EAN-13 or EAN-8 with a valid check digit. Digit groups on a line are joined when the joined length is 8 or 13 and the checksum validates; a 13-digit number is never split into a 9-digit `aic`. `CodeCandidate.eanFromBarcode(String value, Rect box)` lets Task 2 add ML Kit barcode results (`findCodeCandidates(..., barcodes:)`), deduplicated with OCR-found EANs; the barcode-decoded box wins.
- `aic`: `BarcodeLookupDatasource.aicPattern` matches minus numbers claimed by `supplement` or inside an `ean`. `aicPattern` / `extractCodes` now require non-digit boundaries: `(?<![0-9])[A-Za-z]?\d{6,9}(?![0-9])`.
- `other`: unchanged (≥ 6 alphanumerics with ≥ 4 digits, not overlapping any of the above).
- Ranking: `aic` (9-digit before shorter), `supplement`, `ean`, `other`; within a kind top-to-bottom, left-to-right; dedupe by `kind + code`.
- Review sections in order: `scanAicCodes`; `scanSupplementCodes` "Supplement codes (Ministry of Health)" / "Nahrungsergänzungsmittel (Ministeriumscode)" / "Codici integratori (Ministero della Salute)"; `scanBarcodes` "Barcodes (EAN)" / "Barcodes (EAN)" / "Codici a barre (EAN)"; `scanOtherNumbers`. Markers: AIC `primaryContainer`/`primary`, supplement `tertiaryContainer`/`tertiary`, EAN `secondaryContainer`/`secondary`, other `outline`.
- Extra tests: the photo's lines yield exactly one `supplement` `107018`, one `ean` `8057737141836` and no `aic`; `COD. MIN. SAN.`, `Cod. Minsan 107018` and label-on-previous-line variants; invalid checksum `8057737141837` is not `ean`; EAN-8 `96385074` validates; `eanFromBarcode` dedupes with an OCR EAN; unit tests for `extractCodes`.
- Commit message: `feat(scanner): rank AIC, supplement, EAN and other code candidates; review them on the photo`.

### Task 2: Photo capture flow in the scanner screen

**Files:** `lib/presentation/screens/scanner/barcode_scanner_screen.dart`, ARB cleanup, `docs/architecture.md` (one paragraph), README feature bullet.

- [ ] **Step 1: State machine** — `enum _ScanStage { capture, recognizing, review }`. Remove `startImageStream`, `_processImageStream`, `_processOcrFrame`, `_convertCameraImage`, `_concatenatePlanes`, `_rotationFromSensorOrientation`, `_detectedTexts`, `_aicCodes`, `_isPaused`, `_isProcessingFrame`. `CameraController(back, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg)`; after `initialize()` → `setFocusMode(FocusMode.auto)`; tap on preview → `setFocusPoint` at the tapped normalised offset.
- [ ] **Step 2: Capture UI** — preview fills the body (existing `FittedBox` cover); bottom bar: gallery `IconButton`, large circular shutter `FilledButton` (`scanTakePhoto` tooltip/semantics), manual-entry `IconButton`; scrim hint `scanCaptureHint`; torch in the AppBar (existing).
- [ ] **Step 3: Capture → recognize** — shutter: `final file = await controller.takePicture()`; gallery: `ImagePicker().pickImage(source: ImageSource.gallery)` (no downscale). Stage `recognizing` shows the photo dimmed with a spinner and `scanRecognizing`. `final recognized = await _textRecognizer.processImage(InputImage.fromFilePath(path))`; `final candidates = findCodeCandidates(ocrLinesFrom(recognized))`; `final size = await _decodeSize(path)` (`decodeImageFromList(await File(path).readAsBytes())` → `Size(image.width, image.height)`, dispose the `ui.Image`). Stage `review`. Pause the camera preview while not capturing (`pausePreview()`/`resumePreview()`). Errors (camera, OCR, decode) → snackbar `genericError`, back to `capture`.
- [ ] **Step 4: Review → existing flow** — `ScanReviewView(image: FileImage(file), …, onSelected: (c) => _handleCode(c.code), onRetake: _retake, onManualEntry: () => _showManualEntryDialog(context), busy: _isSearching)`. `_handleCode` unchanged except: remove `_isPaused` bookkeeping; on "not found" stay in `review` so the user can pick another code (snackbar `barcodeNotFound`). `_retake` deletes the temp file (only for camera captures), clears candidates, `resumePreview()`, stage `capture`. Delete the temp file after a successful selection and in `dispose`.
- [ ] **Step 5: Lifecycle** — keep the inactive/resumed handling but re-init the camera only when stage is `capture` (review keeps the photo); `mounted` checks after every await.
- [ ] **Step 6: Tests** — the camera and ML Kit are not testable in widget tests; extract `@visibleForTesting static Future<ScanResult> recognizeFile(String path, TextRecognizer r)`? No — keep the screen thin and rely on Task 1 tests. Add one widget test that pumps `BarcodeScannerScreen` with `platformCapabilitiesProvider` desktop-with-camera override is NOT possible (plugins) — instead assert via `flutter analyze` and the on-device check in Task 3. Grep and delete now-unused ARB keys; gen-l10n.
- [ ] **Step 7: Verify** gates; `fvm flutter build apk --debug --target-platform android-arm64` compiles (delete `build/` afterwards if disk is tight). **Commit** — `feat(scanner): take a photo, then choose the AIC code`

---

### Task 3: On-device verification and release

- [ ] Build a release-signed arm64 split APK labelled `0.2.3+15` from the merged tree; install on the attached phone (`adb -s RZCXA1ZEXJE`).
- [ ] Render a test image with the text lines `AIC n. 034567891`, `Lotto 4R5T21`, `Scad. 03/2027` (`magick -size 1600x900 xc:white -font DejaVu-Sans -pointsize 72 -annotate …`), `adb push` it to `/sdcard/Pictures/`, trigger a media scan, open the scanner, choose it from the gallery, and confirm on screen: overlay markers on the three lines' codes, list shows `034567891` under AIC codes and `4R5T21` under other numbers; tap the AIC row → AIFA lookup runs (a snackbar or result picker appears). Screenshots for the report.
- [ ] Camera capture smoke test: shutter produces the review stage (any scene).
- [ ] Merge to `main`, `tools/release.sh 0.2.3+15`, confirm the Release assets and CI.

## Exit criteria
- [ ] No image stream; one photo (or gallery image) per scan; OCR runs once per photo.
- [ ] Review shows the photo with numbered overlays and a ranked list (AIC first); tapping either uses that code.
- [ ] Return-only mode fills the Add Medication field; full mode runs the AIFA lookup as before; manual entry still works.
- [ ] Temp photos are deleted; gates green; goldens unchanged; l10n complete; verified on the phone; release `v0.2.3+15` published.

---

## Amendment (2026-09-15): barcodes on the photo and the food-supplement register

The user photographed a food supplement (not a medicine). Its label carries `COD MINSAN: 107018` (the Ministry of Health notification code) and an EAN-13 barcode `8057737141836`. Supplements are not in the AIFA medicines file. The Ministry publishes the register of notified supplements monthly as a PDF (`/new/sites/default/files/INTEGRATORI_NOTIFICATI_ORD_PROD_<n>.pdf`, ~4,100 pages, columns PRODOTTO / IMPRESA / CODICE); `107018` is listed as `ZINCO-C`, company `SYGNUM SRL`. A prototype parser (`pdftotext -bbox-layout` + per-page column positions) yields 113,925 rows, 1.8 MB gzipped. Open Food Facts does not know this EAN, so EANs are used for matching the user's own cabinet only.

Task 1 was amended in its dispatch (candidate kinds `aic`, `supplement`, `ean`, `other`; `extractCodes` boundary fix). The following changes Task 2 and adds Task 3; the old Task 3 becomes Task 4.

### Task 2 additions: decode barcodes on the same photo

- Add `google_mlkit_barcode_scanning` (^0.16.1; shares `google_mlkit_commons` 0.13 with text recognition). Run `BarcodeScanner(formats: [ean13, ean8, code39, code128, dataMatrix])` on the same `InputImage` as the text recogniser (in parallel).
- Map decoded barcodes to candidates with `CodeCandidate.eanFromBarcode` for EAN-13/EAN-8; a Code 39 / Code 128 value `A` + 9 digits (the medicine "bollino") becomes an `aic` candidate; anything else is `other`. Barcode boxes come from `Barcode.boundingBox`; merge with OCR candidates via the Task 1 dedupe rules (barcode wins).
- Selecting a candidate: `aic` → existing AIFA flow; `supplement` → Task 3 register lookup; `ean` → look up the user's cabinet by barcode (`MedicationRepository.getMedicationByBarcode`); if found open that medication's detail, otherwise open Add Medication with the barcode prefilled; `other` → return-only mode returns it, full mode opens Add Medication with it prefilled.

### Task 3: food-supplement register (data pipeline + offline lookup)

**Files:**
- Create: `tools/build_supplements_data.py` (from the validated prototype), `.github/workflows/supplements-data.yml`, `lib/services/supplement_registry_service.dart`, `test/services/supplement_registry_service_test.dart`, `test/fixtures/integratori_sample.csv`
- Modify: scanner selection for `supplement` candidates, Settings → Data (register tile next to the AIFA tile), `lib/presentation/screens/medication/add_medication_screen.dart` (accept a supplement prefill), ARB, `docs/architecture.md`, `docs/release.md`, README.

**Data pipeline:**
- `supplements-data.yml`: `on: schedule: cron '0 5 3 * *'` (3rd of each month) + `workflow_dispatch`; ubuntu, `apt-get install -y poppler-utils`, run `tools/build_supplements_data.py --out integratori.csv.gz`, then publish to the fixed release tag `data-integratori` (create if missing, `gh release upload --clobber`), as a pre-release so `releases/latest` (the app updater) never picks it. Also upload `integratori.meta.json` `{ "rows": N, "sourceUpdated": "<aggiornato al date>", "builtAt": "<UTC>" }`.
- The Ministry site may block GitHub runner IPs. The workflow must fail loudly (`not a PDF`) in that case; document the manual fallback in `docs/release.md`: run the script locally (from Italy) and `gh release upload data-integratori integratori.csv.gz integratori.meta.json --clobber`. The controller performs the first upload manually from the prototype output if the runner is blocked.

**App:**
```dart
class SupplementEntry { final String code; final String product; final String company; }
class SupplementRegistryService {
  SupplementRegistryService({http.Client? client, Future<Database> Function()? openDatabase, DateTime Function()? now});
  static const dataUrl = 'https://github.com/13/medora/releases/download/data-integratori/integratori.csv.gz';
  Future<int> sync({void Function(double progress)? onProgress}); // streamed download, gunzip, batch insert into `supplements(code TEXT, product TEXT, company TEXT)` in its own sqflite DB `supplement_cache.db` with an index on code; replaces the table in one transaction; stores count + sync time in prefs
  Future<List<SupplementEntry>> findByCode(String code); // strips non-digits and leading zeros-insensitive match
  Future<List<SupplementEntry>> searchByName(String query, {int limit = 50});
  Future<DateTime?> lastSync(); Future<int> count();
}
```
- Mirrors `AifaCacheService` (same UX): Settings → Data tile "Food supplement register" / "Nahrungsergänzungsmittel-Register" / "Registro integratori" with last update, count and an update button; the scanner offers to download it the first time a supplement code is selected while the cache is empty (dialog; online required).
- Scanner `supplement` selection: `findByCode`; one match → open Add Medication prefilled (name = product, manufacturer = company, category = supplement/"Nahrungsergänzungsmittel" per existing category values, barcode = the scanned code) with snackbar `autoFilledFromBarcode`; several → picker like the AIFA result picker; none → snackbar `supplementNotFound` and Add Medication with the code prefilled.
- Tests: CSV fixture with 3 rows incl. `107018,ZINCO-C,SYGNUM SRL` and a quoted company containing a comma; `MockClient` serving the gzipped fixture; `sync` inserts rows and records count; `findByCode('107018')` and `findByCode('0107018')` match; `searchByName('zinco')` case-insensitive; a non-gzip / HTTP error leaves the previous table intact; parser script: a `python3 -m doctest`-free smoke test is not required in Dart CI, but the workflow runs the script with `--min-rows 50000`.
- ARB (en/de/it): `supplementRegister`, `supplementRegisterHint`, `supplementNotFound`, `supplementRegisterDownloadPrompt`, `scanSupplementSelected`.

### Task 4: On-device verification and release (was Task 3)

In addition to the original steps: render the supplement label test image (lines from the user's photo including `COD MINSAN: 107018` and an EAN-13 barcode image generated with a barcode tool or the user's photo itself), pick it from the gallery, confirm the `supplement` and `ean` candidates, select `107018` → Add Medication prefilled with `ZINCO-C` / `SYGNUM SRL`.
