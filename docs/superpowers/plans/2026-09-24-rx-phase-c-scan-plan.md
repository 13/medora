# Prescription Scan (Phase C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prescription by photographing or picking the paper/PDF: barcodes and text are read on the device, the form opens prefilled, the original is attached. Also align the model and pharmacy view with real South Tyrol prescriptions (Code 128, NRBE + PIN).

**Architecture:** A pure-Dart `RxExtractor` turns decoded barcode values plus recognised text into an `RxDraft`. A `RxScanService` feeds it from an image (ML Kit barcode + text recognition, four rotations) or a PDF (text layer + first page rasterised with `pdfrx`). The form accepts a draft; after saving, the original is stored as an attachment (phase B). The pharmacy view renders Code 128 exactly like the paper.

**Tech Stack:** Flutter 3.44.6 (fvm), Dart 3.12.2, google_mlkit_barcode_scanning / text_recognition (existing), `pdfrx` (new), Riverpod 3, sqflite, Supabase.

**Spec:** `docs/superpowers/specs/2026-09-23-prescription-rx-design.md` §8 and §11 (addendum with the calibration from real prescriptions).

## Global Constraints

- Always `fvm flutter …` / `fvm dart …`. CI gates after every task: gen-l10n no diff, `fvm dart format --output=none --set-exit-if-changed lib test`, `fvm flutter analyze --fatal-infos`, `fvm flutter test` (one full run per task, in the foreground; ~5 min is normal).
- **Privacy:** the user's real prescription photos live only in `~/.claude/uploads/…`; never copy them into the repo, never commit real names, tax codes, NREs, PINs, addresses or authentication codes. All fixtures use the invented data below.
- Invented fixture data: patient **ROSSI MARIO**, tax code **RSSMRA85T10A562S**; doctor **BIANCHI LUCA**, tax code **BNCLCU70A01A952Z**; SSN NRE **041A0** + **0012345678** (= `041A00012345678`); white NRBE **G00001234567**, PIN **7XQ2K**; issue date **03/03/2026**. Product names/AIC codes of real medicines (public register data) are fine.
- Everything on-device: no network OCR. Every value read from a scan is a suggestion the user confirms in the form.
- Strings in EN/DE/IT ARB files (metadata only in EN). Every repository `Result` from a user action surfaces failures; `context.mounted` after awaits.
- Local schema: migration **19**. Server: the rx migration `supabase/migrations/20260923000000_rx.sql` is unreleased and never applied persistently — edit it in place for the new column.
- Never copy the repo or create worktrees (disk ~99% full); scratch only in the session scratchpad; delete scratch files after.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01GYoavdFqZj1sBjFR7FE5wh`
- Branch: `rx-phase-c`.

---

### Task 1: NRBE and PIN in the model, form and sync

**Files:**
- Modify: `lib/domain/rx/nre.dart` (NRBE + PIN validators, NRE split), `lib/domain/entities/rx.dart` (`pin`), `lib/data/models/rx_model.dart`, `lib/data/datasources/rx_local_datasource.dart`, `lib/data/local/migrations.dart` (19: `ALTER TABLE rx ADD COLUMN pin TEXT`), `supabase/migrations/20260923000000_rx.sql` (`pin text` column + `check (pin is null or pin ~ '^[A-Z0-9]{5}$')`), `lib/data/sync/row_merge.dart` (`pin` joins the `nre` group: add a group `{'nre', 'pin'}`), `test/helpers/fake_server.dart` (schema `pin`), `tools/sql/*` if a check lists rx columns, `lib/presentation/screens/rx/rx_form_screen.dart` (PIN field for white kinds; NRE label/validation by kind), `lib/domain/rx/rx_rules.dart` (source comment: repeatable 6 months/10 confirmed by a real 2026 prescription text), l10n keys
- Test: `test/domain/rx/nre_test.dart`, `test/data/datasources/rx_local_datasource_test.dart`, `test/presentation/screens/rx/rx_form_screen_test.dart`, sync round-trip fixture in `test/data/sync/sync_meta_test.dart`

**Interfaces:**
- Produces:
  ```dart
  abstract final class Nre {
    static String normalize(String raw);            // existing
    static bool isValid(String raw);                 // SSN NRE: exactly ^[0-9]{3}[A-Z][0-9]{11}$ (15)
    static bool isNrbe(String raw);                  // white electronic: ^[A-Z][0-9]{11}$ (12)
    static bool isPin(String raw);                   // ^[A-Z0-9]{5}$
    /// The two barcodes printed on the SSN paper: first 5 and last 10 chars.
    static (String, String)? split(String nre);      // null unless isValid
  }
  // Rx gets `final String? pin;` (copyWith, model wire key 'pin').
  ```
  Tighten `isValid` to the SSN shape above (check existing tests: `0410A1234567890` still matches; `0410a 12345 67890` normalises to it). Keep a 15-alnum test only if it still holds; update tests that relied on looser shapes.
- Form rules: kind `ssn`/`referral` → field label `rxNre`, validator `Nre.isValid`, no PIN field. Kinds `white`/`whiteRepeatable` → label `rxNrbe` ("Prescription number (NRBE)" / "Rezeptnummer (NRBE)" / "Numero ricetta (NRBE)"), validator `Nre.isNrbe` (empty allowed: a paper white prescription has none), PIN field (`rxPin`: "PIN" in all languages; hint `rxPinHint` EN "5 characters under the NRBE barcode" / DE "5 Zeichen unter dem NRBE-Barcode" / IT "5 caratteri sotto il codice a barre NRBE"), required iff an NRBE is entered, validator `Nre.isPin`, error `rxPinInvalid` EN "5 letters or digits" / DE "5 Buchstaben oder Ziffern" / IT "5 lettere o cifre". Duplicate check stays on `nre` (NRE or NRBE are both unique numbers).

- [ ] Steps: failing tests (validators, model round-trip incl. `pin`, local migration 19 adds the column, form validation per kind) → implement → focused tests → one full suite → commit `feat(rx): white electronic prescriptions carry NRBE and PIN`.

---

### Task 2: Code 128 pharmacy view like the paper

**Files:**
- Create: `lib/presentation/widgets/code128.dart` (encoder + painter, reusing the quiet-zone/whole-pixel layout of `code39.dart`: move `layout` and `darkRuns` into a shared `lib/presentation/widgets/barcode_layout.dart`)
- Modify: `lib/presentation/screens/rx/pharmacy_screen.dart`, `lib/presentation/screens/rx/rx_detail_screen.dart` (what it passes), delete `code39.dart` and its test if nothing else uses it (keep its layout tests by moving them)
- Test: `test/presentation/widgets/code128_test.dart`, `test/presentation/screens/rx/pharmacy_screen_test.dart`

**Interfaces:**
- Produces:
  ```dart
  abstract final class Code128 {
    /// Code 128 modules (true = dark) for [data], with start, checksum and
    /// stop; set C for an all-digit string of even length ≥ 4, else set B.
    /// Null when a character is outside set B (ASCII 32–127).
    static List<bool>? encode(String data);
  }
  class Code128Barcode extends StatelessWidget { const Code128Barcode(this.data, {super.key, this.height = 96}); }
  class PharmacyScreen extends StatelessWidget {
    const PharmacyScreen({required String title, required List<PharmacyCode> codes});
  }
  class PharmacyCode { const PharmacyCode({required this.label, required this.value}); final String label; final String value; }
  ```
- `RxDetailScreen` builds the codes: SSN (`Nre.split` succeeds) → `rxNrePart1` label "NRE 1/2", value part 1; "NRE 2/2", part 2; white with NRBE → "NRBE", then "PIN" when set; then the person's tax code (`rxTaxCode`) when known. Show-at-pharmacy button appears when at least one code exists.

- [ ] **Step 1: Encoder tests** — known encodings (verify each against a reference, e.g. the Code 128 table on Wikipedia):
  - `encode('7XQ2K')` (set B) and `encode('0012345678')` (set C) have the right start code (B = 104, C = 105), checksum and stop pattern (`11000111010` + final `11` bar), total module count = 11 × (symbols + start + check) + 13.
  - Characters outside ASCII 32–127 → null.
- [ ] **Step 2: Decode check** — a test renders `Code128Barcode` for `041A0`, `0012345678`, `G00001234567`, `7XQ2K`, `RSSMRA85T10A562S` at 360 dp × dpr 3 to PNGs in a temp dir (`RepaintBoundary.toImage`, `tester.runAsync`). The controller verifies them after the task with zxing locally; the test itself asserts only the pixel run widths are whole multiples of the module. Report the PNG paths.
- [ ] **Step 3:** implement; pharmacy screen widget test (SSN shows two NRE codes + tax code; white shows NRBE + PIN + tax code; labels shown). Full suite. Commit `feat(rx): pharmacy view prints Code 128 like the paper`.

---

### Task 3: Extractor

**Files:**
- Create: `lib/domain/rx/rx_draft.dart`, `lib/domain/rx/rx_extractor.dart`, `test/domain/rx/rx_extractor_test.dart`, `test/fixtures/rx_scan/ssn_promemoria.txt`, `test/fixtures/rx_scan/white_promemoria.txt`
- Modify: `lib/domain/entities/rx.dart` (`RxItem.posology`, JSON key `posology`), rx form item row + detail item tile (show/edit posology), `test/…` round-trip

**Interfaces:**
```dart
class RxDraftItem {
  const RxDraftItem({this.aic, required this.description, this.packs = 1, this.posology});
  final String? aic; final String description; final int packs; final String? posology;
}

class RxDraft {
  const RxDraft({this.kind, this.nre, this.pin, this.taxCode, this.patientName,
    this.doctor, this.doctorTaxCode, this.issuedOn, this.validUntil,
    this.maxDispensings, this.exemptionCode, this.priority, this.items = const [],
    this.fromBarcode = const {}});
  final RxKind? kind; final String? nre; final String? pin; final String? taxCode;
  final String? patientName; final String? doctor; final String? doctorTaxCode;
  final DateTime? issuedOn; final DateTime? validUntil; final int? maxDispensings;
  final String? exemptionCode; final RxPriority? priority; final List<RxDraftItem> items;
  /// Field names read from a barcode (trusted) rather than text (suggested):
  /// 'nre', 'pin', 'taxCode', 'doctorTaxCode'.
  final Set<String> fromBarcode;
  bool get isEmpty; // nothing recognised at all
}

abstract final class RxExtractor {
  /// [barcodes]: decoded values in the order found; [text]: all recognised
  /// text, lines joined with '\n' in reading order (order may be imperfect);
  /// [knownTaxCodes]: tax codes of persons on this device (a match is the patient).
  static RxDraft extract({required List<String> barcodes, required String text, Set<String> knownTaxCodes = const {}});
}
```

Rules (all case-insensitive on an upper-cased copy of the text, whitespace collapsed per line):
1. **Barcodes** (strip `*`, spaces; upper-case):
   - `^[0-9]{3}[A-Z][0-9]$` → NRE part 1; `^[0-9]{10}$` → NRE part 2; both → `nre = p1 + p2` if `Nre.isValid`.
   - `^[A-Z][0-9]{11}$` → NRBE → `nre`.
   - `^[A-Z0-9]{5}$`, not an NRE part 1, and an NRBE present → `pin`.
   - `TaxCode.isValid` → tax code candidates (ordered).
   - Anything else (QR text, EANs) ignored.
2. **Patient vs doctor tax code:** a candidate in `knownTaxCodes` is the patient. Otherwise, for each candidate find its first occurrence in the text and the nearest *preceding* label within 250 characters: patient labels `ASSISTITO|PAZIENTE|BETREUTEN|PATIENTEN`, doctor labels `MEDICO|ARZT|ARZTES|MED\.` — assign accordingly. Unresolved: the first barcode candidate is the patient, the next is the doctor. Also read tax codes from text when no barcode had them (`[A-Z]{6}[0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z]` with `TaxCode.isValid`) — marked as text, not barcode.
3. **Kind:** text contains `RICETTA BIANCA` → white (or `whiteRepeatable` when `RIPETIBILE` and `VOLTE` appear); else NRE found or `ASSIST.SSN`/`PROMEMORIA PER L'ASSISTITO` → `ssn`; else null. (`non a carico del SSN` appears on white prescriptions — check `BIANCA` first.)
4. **Dates:** issued = first `(?:DATUM/DATA|AUSSTELLUNGSDATUM|DATA COMPILAZIONE)[^0-9]{0,40}([0-9]{2})/([0-9]{2})/([0-9]{4})`; validity = `(?:GÜLTIG BIS ZUM|GULTIG BIS ZUM|VALIDA FINO AL)[^0-9]{0,40}(dd/mm/yyyy)` else `(?:VALIDA PER|GÜLTIG FÜR|GULTIG FUR)\s+([0-9]{1,3})\s+(?:GIORNI|TAGE)` → issued + n calendar days. Invalid dates (e.g. 31/02) → null.
5. **Repeat count:** `(?:PER|FÜR|FUR)\s+([0-9]{1,2})\s+VOLTE` → `maxDispensings`.
6. **Exemption:** `ESENZIONE\s*:\s*([A-Z0-9]{2,6})\b` unless the value starts `NON`; `NICHT BEFREIT`/`NON ESENTE` → null.
7. **Priority:** `PRIORIT[AÀ]'?\s*PRESCRIZIONE\s*\(U,B,D,P\)\s*:\s*([UBDP])\b`.
8. **Names:** patient `(?:ZUNAME UND NAME DES BETREUTEN|COGNOME E NOME DELL'ASSISTITO|COGNOME E NOME DEL PAZIENTE)[^:]*:\s*([A-ZÀ-Ü' ]{3,}?)(?=\s{2,}|\s[0-9]|$)` (first line only); doctor `(?:ZUNAME UND NAME DES ARZTES|COGNOME E NOME DEL MEDICO)[^:]*:\s*([A-ZÀ-Ü' ]{3,})` (first line only) — stored title-cased ("Bianchi Luca").
9. **Items:** per line, an AIC is 9 digits, allowing one OCR space and `O`→`0` inside the digit run: `(?<![0-9])\(?([0-9O]{8}\s?[0-9O])\)?\s*-?\s*([A-Z][^\n]{2,}?)\s*(?:QTA/MENGE\s*:\s*([0-9]+))?$`. The 9-digit run must not touch other digits on either side (add a `(?![0-9])` after it), so authentication codes and phone numbers never match. Description = trimmed name part: drop a trailing `QTA/MENGE…`, and a trailing standalone number (the SSN quantity column, e.g. `… 500MG 1`) which then becomes the packs. Packs: the `QTA/MENGE` on the same or following line, else the single value of `N.CONFEZIONI/PRESTAZIONI:\s*([0-9]+)` when there is exactly one item, else 1. Posology: the n-th `POSOLOGIA/POSOLOGIE\s*:\s*(.+)` belongs to the n-th item; on SSN promemoria, the text after the last ` - ` on the line following an item line when that line starts with `(EGA)` or `USO` (e.g. `1x3 bei Bedarf`).
10. `fromBarcode` lists the fields taken from barcodes.

**Fixtures** (write them exactly; they imitate the ML Kit line output of the two real layouts with invented data):

`test/fixtures/rx_scan/ssn_promemoria.txt`:
```
STAATLICHER GESUNDHEITSDIENST
SERVIZIO SANITARIO NAZIONALE
ELEKTRONISCHE VERSCHREIBUNG - MERKZETTEL FÜR DEN BETREUTEN
RICETTA ELETTRONICA-PROMEMORIA PER L'ASSISTITO
AUTONOME PROVINZ BOZEN-SÜDTIROL
PROVINCIA AUTONOMA DI BOLZANO-ALTO ADIGE
*041A0*
*0012345678*
*RSSMRA85T10A562S*
ZUNAME UND NAME DES BETREUTEN:ROSSI MARIO 10/12/1985
COGNOME E NOME DELL'ASSISTITO:
ADRESSE: VIA ROMA 1 39100 BOLZANO BZ
BEFREIUNG:NICHT BEFREIT PROVINZKENNZEICHEN:BZ KODE SB-201
ESENZIONE:NON ESENTE SIGLA PROVINCIA: CODICE ASL:
VERSCHREIBUNGSTYPOLOGIE: DRINGLICHKEIT DER VERSCHREIBUNG:
TIPOLOGIA PRESCRIZIONE(S,H): PRIORITA' PRESCRIZIONE (U,B,D,P):
Verschreibung gültig für 30 Tage
PRESCRIZIONE VALIDA PER 30 GIORNI
MENGE QTA
(012345678) PARACETAMOLO*20CPR 500MG 1
(EGA) PARACETAMOLO 500MG 20 UNITA' USO ORALE - 1x3 bei Bedarf
NR PACKUNGEN/LEISTUNGEN: ART DER VERSCHREIBUNG: DATUM/DATA:
N.CONFEZIONI/PRESTAZIONI:1 TIPO RICETTA:Assist.SSN 03/03/2026
STEUERN. DES ARZ./COD. FIS. MED. BNCLCU70A01A952Z
ZUNAME UND NAME DES ARZTES:BIANCHI LUCA
COGNOME E NOME DEL MEDICO:
CODICE AUTENTICAZIONE:030320261234567890123456
```

`test/fixtures/rx_scan/white_promemoria.txt`:
```
Prescrizione di farmaci non a carico del SSN - Ricetta Bianca Elettronica - Promemoria per il paziente
Verschreibung von Medikamenten, welche nicht zu Lasten des NG sind - Weißes elektronisches Rezept - Merkzettel für den Patienten
NRBE
G00001234567
C.F. PAZIENTE/STEUERNUMMER DES PATIENTEN
RSSMRA85T10A562S
PIN-NRBE
7XQ2K
COGNOME E NOME DEL PAZIENTE/NACHNAME UND NAME DES PATIENTEN:
PRESCRIZIONE/VERSCHREIBUNG: 011111111 - IBUPROFENE*12CPR 400MG QTA/MENGE: 1
POSOLOGIA/POSOLOGIE: 1 ABENDS TDL: NO/NEIN
NOTE DEL MEDICO/ANMERKUNGEN DES ARZTES: BEI FIEBER
RIPETIBILE PER/WIEDERHOLBAR FÜR 10 VOLTE E VALIDA FINO AL/MAL UND GÜLTIG BIS ZUM: 03/09/2026
PRESCRIZIONE/VERSCHREIBUNG: 022222222 - SALINA*SPRAY NASALE 20ML QTA/MENGE: 1
POSOLOGIA/POSOLOGIE: 3X TÄGLICH TDL: NO/NEIN
RIPETIBILE PER/WIEDERHOLBAR FÜR 10 VOLTE E VALIDA FINO AL/MAL UND GÜLTIG BIS ZUM: 03/09/2026
COGNOME E NOME DEL MEDICO/NACHNAME UND NAME DES ARZTES: BIANCHI
LUCA
CODICE FISCALE/STEUERNUMMER
BNCLCU70A01A952Z
SPECIALIZZAZIONE/SPEZIALISIERUNG: Medico di Medicina Generale
DATA COMPILAZIONE/AUSSTELLUNGSDATUM : 03/03/2026
```

- [ ] **Step 1: Tests** (`test/domain/rx/rx_extractor_test.dart`), reading the fixtures:
  - SSN: barcodes `['041A0','0012345678','RSSMRA85T10A562S']` + text → kind `ssn`, nre `041A00012345678`, taxCode `RSSMRA85T10A562S`, doctorTaxCode `BNCLCU70A01A952Z` (from text), doctor `Bianchi Luca`, patientName `Rossi Mario`, issuedOn 2026-03-03, validUntil 2026-04-02, exemption null, priority null, one item aic `012345678` "PARACETAMOLO*20CPR 500MG" packs 1 posology `1x3 bei Bedarf`, `fromBarcode` = {nre, taxCode}.
  - White: barcodes `['STAMPATO DA SISTEMATS - RICETTA BIANCA','G00001234567','7XQ2K','RSSMRA85T10A562S','BNCLCU70A01A952Z']` → kind `whiteRepeatable`, nre `G00001234567`, pin `7XQ2K`, taxCode patient `RSSMRA85T10A562S`, doctorTaxCode `BNCLCU70A01A952Z`, issuedOn 2026-03-03, validUntil 2026-09-03, maxDispensings 10, doctor `Bianchi` (first line only), two items: `011111111` "IBUPROFENE*12CPR 400MG" posology "1 ABENDS", `022222222` "SALINA*SPRAY NASALE 20ML" posology "3X TÄGLICH".
  - Patient/doctor swap: white barcodes with the doctor's code first and `knownTaxCodes: {'RSSMRA85T10A562S'}` → still the right assignment; without known codes, label proximity decides.
  - Shuffled lines (reverse the fixture's line order) → same NRE/PIN/tax codes/dates/items (items may come in another order; compare as sets).
  - OCR noise: `O` in an AIC (`O12345678`) → `012345678`; a missing barcode (only text) → NRE from text is **not** invented (null), tax codes from text still found but not in `fromBarcode`.
  - Nothing recognisable → `isEmpty`.
- [ ] **Step 2–4:** implement `RxExtractor` as specified; `RxItem.posology` (JSON, optional; form row gets a posology text field, detail shows it); commit `feat(rx): read a prescription from its barcodes and text`.

---

### Task 4: Scan service (image and PDF)

**Files:**
- Modify: `pubspec.yaml` (`fvm flutter pub add pdfrx` — newest that resolves; check Android minSdk and that no network/pdfium download at build time breaks CI; record the version), `lib/services/scanner_ports.dart` (new `RawBarcodePort`), `lib/services/mlkit_scanner_ports.dart` (implementation: `BarcodeScanner(formats: [BarcodeFormat.code128, BarcodeFormat.code39, BarcodeFormat.qrCode, BarcodeFormat.dataMatrix])`, returns `rawValue`s)
- Create: `lib/services/rx_scan_service.dart`, `lib/services/pdf_page_port.dart` (port + pdfrx implementation), tests with fakes

**Interfaces:**
```dart
abstract class RawBarcodePort { Future<List<String>> valuesIn(ScanImage image); Future<void> close(); }
abstract class PdfPagePort {
  /// Text of every page, and page 1 rendered to a PNG file (long edge ~2400 px) for barcodes.
  Future<({String text, String? firstPagePng})> read(String pdfPath);
}
class RxScanService {
  RxScanService({required RawBarcodePort barcodes, required TextRecognitionPort text, required PdfPagePort pdf, required Future<Set<String>> Function() knownTaxCodes});
  /// Photo: barcodes on the image in 0/90/180/270° until at least one value is
  /// found (stop early once an NRE/NRBE and a tax code are in), text once on
  /// the rotation that produced the most barcodes (or 0°). PDF: text layer,
  /// then barcodes on the rendered first page; text OCR on it only when the
  /// PDF has no text layer.
  Future<RxDraft> scanPhoto(String path);
  Future<RxDraft> scanPdf(String path);
}
```
Rotations: reuse the existing rotation helper if `lib/services/scan_passes.dart` has one (it rotates for the stripe pass), otherwise rotate with the `image` package in an isolate after downscaling to 2400 px (same bound as phase B import; 60 MP / 20 MB limits apply — refuse like the import). OCR lines are joined in reading order (sort by `box.top`, then `box.left`). Timeouts: 15 s per pass like `scan_passes.dart`; on timeout continue with what was found. Nothing thrown to the UI: failures become an empty draft plus a flag `RxScanResult.failed` — define `class RxScanResult { final RxDraft draft; final bool failed; }` and return that instead of a bare draft.

- [ ] Tests with fake ports: barcodes found only at 90° → used; early stop after NRE + tax code; PDF with text layer skips OCR; PDF without text layer runs OCR on the page PNG; a port throwing → `failed: true`, empty draft; known tax codes passed through. Commit `feat(rx): scan a prescription photo or PDF`.

---

### Task 5: Scan flow in the UI

**Files:**
- Modify: `lib/presentation/screens/rx/rx_list_view.dart` / `treatment_list_screen.dart` FAB (prescriptions pane): bottom sheet **Camera | Gallery | PDF or file | Enter manually** (camera only with `hasCamera`, file/scan only with `hasFileSystem`); `lib/presentation/screens/rx/treatment_rx_section.dart` add button → same sheet (treatment prefilled); `lib/presentation/screens/rx/rx_form_screen.dart` (`RxFormScreen({…, RxDraft? draft, String? originalPath, AttachmentKind? originalKind})`), router (`AppRoutes.addRx` carries the draft via `state.extra`)
- Create: `lib/presentation/screens/rx/rx_scan_sheet.dart` (source picker + progress "Reading the prescription…"), providers for `RxScanService`
- Test: widget tests under `test/presentation/screens/rx/`

Behaviour:
- Pick (camera/gallery via `AttachmentPicker` from phase B with its 2400 px native downscale; file picker for `pdf,jpg,jpeg,png`) → progress dialog → `scanPhoto`/`scanPdf` → push the form with the draft and the original's path.
- **Form prefill:** kind, NRE/NRBE, PIN, issued, valid-until (as a *picked* value so kind changes keep it), max dispensings, exemption, priority, doctor, items (description, packs, posology, AIC). Fields that came from text show a small "from scan – please check" hint (`rxFromScan`); barcode fields show none.
- **Person:** draft tax code matches a person → preselect. Unknown → a dialog "New person?" (`rxScanNewPerson` with the name read, or "unknown name") offering create (name title-cased, tax code) or skip. Creating goes through `PersonRepository.savePerson`; failure → SnackBar.
- **Duplicate:** draft NRE already saved → SnackBar with "Open" (existing flow) and don't open the form.
- **Nothing recognised** (`draft.isEmpty` or `failed`) → the form opens empty with the SnackBar `rxScanNothing` ("Nothing could be read – please fill in by hand"); the original is still attached on save.
- **Original as attachment:** after `saveRx` succeeds, `AttachmentImport.fromPath(originalPath)` → `AttachmentRepository.add(rx, rxId, imported)`; refusal/failure → SnackBar (the prescription stays saved); then `unawaited(transfer.run())`. Delete the temp original copy afterwards (only inside the app temp dir, like phase B).
- Items with an AIC: after saving, try to link each to a cabinet medication whose AIC (barcode field) equals it — only when exactly one medication matches; no prompt.

Strings (EN / DE / IT): `rxScan` "Scan prescription" / "Rezept scannen" / "Scansiona ricetta"; `rxScanReading` "Reading the prescription…" / "Rezept wird gelesen …" / "Lettura della ricetta…"; `rxScanNothing` as above / "Nichts erkannt – bitte von Hand ausfüllen" / "Nessun dato riconosciuto: compila a mano"; `rxFromScan` "Read from the scan – please check" / "Aus dem Scan – bitte prüfen" / "Letto dalla scansione: controlla"; `rxScanNewPerson` "Add {name} as a person?" / "{name} als Person anlegen?" / "Aggiungere {name} come persona?"; `rxScanManual` "Enter manually" / "Von Hand eingeben" / "Inserisci a mano"; `rxPdfOrFile` "PDF or image file" / "PDF oder Bilddatei" / "PDF o immagine".

- [ ] Widget tests with a fake scan service and fake picker: full SSN draft prefills every field and marks text-derived ones; unknown tax code → new-person dialog → person saved and selected; duplicate NRE → SnackBar, no form; empty result → empty form + message; after save the original is attached (repository fake records `add`). Commit `feat(rx): add a prescription by scanning it`.

---

### Task 6: Docs, device check, whole-branch review

- [ ] `docs/architecture.md`: Prescriptions → "Scanning" subsection (pipeline, barcode classes, what is trusted vs suggested, privacy: on device only). Update the pharmacy-view text (Code 128, SSN split, NRBE+PIN).
- [ ] Controller-run checks (not by a subagent with repo copies): decode the Task 2 PNGs with zxing in the scratch venv; run `RxExtractor` over the barcode values and a transcription of the user's two real prescriptions **locally only** (values from `~/.claude/uploads/…` decoded with zxing), nothing committed.
- [ ] Device checklist for the user (release notes / final message): scan both paper prescriptions with the phone; scan a PDF from the FSE; show-at-pharmacy barcodes read by a phone barcode app.
