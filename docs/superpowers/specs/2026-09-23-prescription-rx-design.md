# Prescriptions (Rezept / ricetta) with scan, attachments and pharmacy view — design

**Date:** 2026-09-23. **Status:** approved in brainstorming. Base: `main` (v0.5.0+23).
Delivered in three phases (A, B, C), each with its own plan and release.

## 1. What the user asked for

> "add feature to take photo/upload document of prescription, what else is missing
> in the prescription especially for south tyrol Verschreibungszettel/Rezept"

The user lives in South Tyrol (Italy). Prescriptions there are Italian NHS (SSN)
prescriptions: mostly *ricetta dematerializzata*. The patient gets a paper
*promemoria* or an SMS/e-mail/FSE PDF carrying the **NRE** (Numero Ricetta
Elettronica) and the patient's **codice fiscale**, both also printed as Code 39
barcodes. The pharmacy needs only those two values.

Decisions taken in brainstorming:

| Question | Decision |
|---|---|
| First-stage goal | Prescription tracker (not just attachments, not OCR→dosing plan) |
| Attachments | Stored locally **and** synced via Supabase Storage |
| Tax code / exemptions | New lightweight **person profile** |
| Linking | Prescription stands alone, optionally linked to a treatment; items optionally linked to a medication; redeeming may add to stock |
| Capture | Barcode-first: NRE + tax code from barcodes, other fields suggested by OCR/PDF text, user confirms |

## 2. What the codebase already has

- `Prescription` (`lib/domain/entities/prescription.dart`) is a **dosing plan**
  (medication, dose, interval, duration). It is not the prescription document.
  The new document entity is therefore named **`Rx`** to avoid a clash.
- `Treatment` already carries sick leave and `doctor`.
- Patients are free-text `patientTags` on a treatment; no person entity.
- Photos: `PhotoStorage` stores medication photos locally (filename only in DB),
  included in the JSON backup, **not** synced.
- ML Kit text + barcode, scan passes, lookalike repair, AIFA lookup all exist
  (`lib/services/scan_passes.dart`, `code_candidates.dart`, `aifa_cache_service.dart`).
- Sync v2: repositories write locally, mark pending, `requestSync`; whole-row LWW;
  stock changes go through the `stock_changes` ledger. Local schema is at 16.
- Data is owner-scoped (`user_id = auth.uid()`); family sharing does not cover
  these tables.

## 3. What is missing for a South Tyrol prescription

| Item | Why it matters |
|---|---|
| NRE (15 chars) | Only thing the pharmacy needs besides the tax code |
| Codice fiscale per person | Pharmacy + identifies whose prescription it is |
| Issue date, valid-until | SSN prescriptions expire (30 days); repeatable white ones last 6 months |
| Type | SSN / white (private) / white repeatable / specialist referral (*impegnativa*) |
| Exemption code (*esenzione*) | Changes ticket and number of packs allowed |
| Priority U/B/D/P | Referrals only; drives booking deadlines |
| Items: AIC/description, packs, *non sostituibile* | What to collect |
| Status + dispensings | Open / partially redeemed / redeemed / expired |
| Attachments | Paper promemoria, PDF, white handwritten prescriptions |
| Show at pharmacy | Barcodes on screen instead of paper |
| Renewal reminder | Chronic medication running low with no open prescription |

## 4. Data model

Local migrations 17+ and one Supabase migration per phase. All synced tables
follow the existing sync-v2 pattern (tombstones, `sync_version`, `write_id`,
keyset pulls, owner-scoped RLS).

### 4.1 `persons` (phase A)

```
id, user_id, name, tax_code?, exemptions TEXT (JSON list, e.g. ["E01","048"]),
notes?, created_at, updated_at, deleted
```

- `tax_code` validated: 16 chars, codice fiscale alphabet, check character.
  Omocodia substitutions accepted.
- `name` is matched loosely to treatment `patientTags` (case-insensitive) to
  suggest the person when creating an Rx from a treatment. Tags stay as they are.

### 4.2 `rx` (phase A)

```
id, user_id, person_id?, treatment_id?,
kind: ssn | white | white_repeatable | referral,
nre?            -- 15 chars; null for white prescriptions
issued_on DATE, valid_until DATE?,
doctor?, exemption_code?, priority?  -- U|B|D|P, referral only
max_dispensings?                     -- white_repeatable
items JSONB     -- list of RxItem, see below
closed_on DATE? -- the user marked it done by hand (e.g. a referral used)
cancelled BOOL, notes?, created_at, updated_at, deleted_at
```

`person_id`, `treatment_id` and each item's `medication_id` are **soft
references**: no foreign key, not sync parents. Deleting a person, treatment or
medication never deletes a prescription; the UI shows "unknown" for a dangling
reference. This keeps `rx` a root table for sync (no orphan handling).

### 4.3 Items (JSON column on `rx`)

```
RxItem { id (uuid), medication_id?, aic?, description, packs INT >= 1,
         non_substitutable BOOL }
```

Items are edited together with their prescription and rarely, so they live in
one column that merges as a whole (last edit wins). Only dispensings need
per-event rows.

### 4.4 `rx_dispensings` (phase A)

```
id, user_id, rx_id, item_id, packs INT >= 1, dispensed_on DATE, pharmacy?,
units_added INT >= 0,   -- units put into the medication's stock (0 = none)
created_at, updated_at, deleted_at
```

Dispensings are their own append-style rows (not a counter on the item), so two
devices redeeming at the same time never lose one to whole-row LWW. `rx_id` is
their sync parent: a prescription's tombstone cascades to them. Medications
carry no pack size, so the redeem dialog proposes `units_added` (packs × the
pack size parsed from the item description, e.g. "20 compresse", else packs)
and the user corrects it.

### 4.5 `attachments` (phase B)

```
id, user_id, owner_kind: rx | treatment | person, owner_id,
kind: photo | pdf, mime, size_bytes, sha256, original_name?, page_count?,
remote_path?   -- null until uploaded
created_at, updated_at, deleted
```

Contents are immutable: a new file is a new attachment.

## 5. Domain rules (pure Dart, unit-tested)

- **Default validity** from `kind` + `issued_on`, via one constants table with a
  source comment per value, always user-editable:
  `ssn` 30 days, `white` 30 days, `white_repeatable` 6 months and at most
  10 dispensings, `referral` no default (the user enters it; the field stays
  empty and the Rx never auto-expires). For referrals the priority instead gives a
  **book-by hint** shown on the card (U 72 h, B 10 days, D 30 days, P 120 days).
  Phase A's first task checks every value against current national/ASDAA
  sources and records the source URL in the table; the table is the only place
  they live.
- **Status** is derived and never stored:
  `cancelled` → cancelled; `closed_on` set, all items fully dispensed, or
  `max_dispensings` reached → redeemed; `valid_until < today` → expired; some dispensed → partial;
  else open.
- **Dispensed packs** per item = sum of non-deleted dispensings.
- **Redeem with "add to stock"** adds `units_added` through
  `MedicationRepository.updateQuantity` (the stock outbox), never a direct
  quantity write.
- **NRE format:** 15 alphanumeric chars; the regional prefix is checked only as a
  hint, never a hard rejection.
- **Duplicate NRE:** saving a second Rx with the same NRE (non-deleted) is refused
  with a link to the existing one.

## 6. Phase A — persons and prescriptions

### 6.1 Navigation

Bottom bar stays at four tabs. The **Treatments** tab gets a segmented control
**Treatments | Prescriptions**. Persons are managed in Settings → Persons.

### 6.2 Prescription list

Groups: *Open* (by `valid_until`, soonest first), *Partially redeemed*,
*Done / expired* (collapsed). Card: person, kind chip, items summary,
"valid 5 more days" / "expired", attachment icon (phase B). Filter by person.

### 6.3 Form

Person (dropdown + "new"), kind, NRE (format check), issue date, valid-until
(prefilled, editable), doctor, exemption (suggested from person), priority
(referral only), treatment (optional). Items: from the cabinet, AIFA search, or
free text; packs; non-substitutable.

### 6.4 Detail

- **Show at pharmacy:** full screen, max brightness, NRE and tax code as Code 39
  barcodes (CustomPainter; no new dependency) plus large text.
- **Redeem:** choose items and packs, date, pharmacy (optional),
  "add to stock" (default on when the item has a medication).
- **Share:** plain text with NRE + tax code (someone else collects).
- Treatment detail gets a "Prescriptions" section with "Add prescription"
  (treatment and person prefilled).

### 6.5 Reminders

Through the existing notification infrastructure and master switch, default on:

- Open Rx expires: 3 days before and on the last day.
- Renewal: a medication with an active dosing plan hits low stock **and** has no
  open Rx item → the existing low-stock notification adds "ask your doctor for a
  prescription".

Home shows an "Rx expiring soon" card alongside the existing banners.

### 6.6 Backup and export

Persons, Rx, items, dispensings in the JSON backup (envelope version bump).
Episode PDF/text export lists NRE, date and items per linked Rx.

## 7. Phase B — attachments

### 7.1 Local

`AttachmentStorage` like `PhotoStorage`, folder `attachments/`, DB stores the
filename. Camera photos are downscaled (long edge ≈ 2400 px, JPEG q85) and EXIF
(including GPS) is stripped. PDFs are kept as-is; limit 20 MB.

### 7.2 Cloud

- Private Supabase Storage bucket `attachments`, object path
  `<auth.uid>/<attachment_id>.<ext>`.
- `storage.objects` policies: select/insert/delete only when the first path
  segment equals `auth.uid()`. No update policy, no public URLs.
- Download through the authenticated client; no signed URLs in logs.

### 7.3 Transfer

A separate `AttachmentTransfer` runs beside the row sync, so row sync never waits
on bytes:

- **Upload queue:** rows with `remote_path = null` and a local file are uploaded,
  then `remote_path` is set and pushed via `requestSync`. Backoff like failing
  rows; only when online.
- **Download:** lazy on open, cached locally; thumbnails prefetched on Wi-Fi.
- **Delete:** tombstone row; the cycle then deletes the object, retried until it
  succeeds.
- A missing remote object (404) shows "file not available on this device yet"
  rather than an error dialog.

### 7.4 Backup, wipe, display

Backup includes attachments under the existing "include photos" option and size
hint. Local wipe deletes the folder; remote wipe (`sync_wipes`) also empties the
user's storage folder. Rx detail shows a gallery (full screen,
`InteractiveViewer`); PDFs open via `open_filex`.

The Supabase migration (table + bucket + policies) must be applied before devices
update; release notes say so and the push error names the migration file.

## 8. Phase C — scan and extraction

### 8.1 Inputs

FAB "Add prescription": **Camera | Gallery | PDF/file | Manual**. Share-target
("open with Medora") is out of scope, noted as a follow-up.

### 8.2 Pipeline (`RxExtractor`, behind the existing scanner ports)

1. **Image:** ML Kit barcodes (Code 39, Data Matrix, QR), four rotations, reusing
   `scan_passes`; ML Kit text.
2. **PDF:** text layer read directly; page 1 rasterised for barcodes and the
   thumbnail. New dependency **`pdfrx`** (pdfium: text + raster).
3. **Classify:** tax code (16 chars + valid check char) and NRE (15 chars) from
   barcodes first, then from text.
4. **Text regexes, German and Italian labels:** issue date near "Data/Datum",
   exemption near "Esenzione/Befreiung", 9-digit AIC codes resolved through AIFA,
   kind hints ("ripetibile", "Priorità U/B/D/P", "non sostituibile"). Lookalike
   repair reused.
5. **Person match** by tax code; unknown → "create person?" with OCR name.
6. **Result:** `RxDraft` with per-field confidence; the form opens prefilled with
   scanned fields marked. The original is **always** saved as an attachment.

### 8.3 Limits

- Nothing recognised → empty form with the attachment and a note.
- Existing NRE → link to the existing Rx, no duplicate.
- Handwritten white prescriptions → attachment + date attempt only; the UI says so.
- Everything on-device (ML Kit, pdfium); no cloud OCR.

### 8.4 Fixtures

Anonymised scans with fake tax code/NRE: SSN promemoria, white prescription,
referral, FSE PDF. The user provides one real South Tyrol sample (redacted) to
calibrate the NRE prefix and label keywords.

## 9. Testing

- Domain unit: validity table, status derivation, dispensing sums, tax code check
  character (incl. omocodia), NRE format, duplicate NRE.
- Extractor: fixture texts / barcode lists → `RxDraft`.
- Sync: persons, rx, items, dispensings round-trip; concurrent dispensings from
  two devices both survive; attachment row push after upload.
- `AttachmentTransfer` with a fake storage port: queue, backoff, tombstone delete,
  404 handling.
- Widgets: form validation, list grouping, pharmacy screen golden.
- Integration (local Supabase): migration applies, storage policies deny another
  user's folder.
- CI gates unchanged (gen-l10n diff, format, analyze --fatal-infos, test).
  All strings in EN/DE/IT.

## 10. Out of scope

Share-target intake; family-shared prescriptions; FSE/SPID integration; ticket
cost calculation; full layout parsing of the promemoria; OCR → dosing plan.
