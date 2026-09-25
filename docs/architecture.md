# Medora — architecture overview

Offline-first Flutter app: everything works with no network and no account, and
Supabase sync is an optional layer on top. This file is the map; the design
rationale lives in `docs/superpowers/specs/`.

`docs/superpowers/plans/` holds the implementation plans those specs were
built from. They are a record of how each piece was approached, not a status
board: their `- [ ]` step boxes were never ticked as the work went, so read
them as history and this file (plus the git log) for what is true now.

## Layers

`lib/` is split by responsibility, dependencies pointing inwards only:

| Directory | Responsibility |
|---|---|
| `lib/core/` | Constants, theme + `MedoraColors` extension, `AppConfig` (dart-defines), `Result`, the `Now` clock, platform capabilities. |
| `lib/domain/` | Entities (`medication`, `treatment`, `prescription`, `dose_log`, `family`, `family_member`) and repository interfaces. No Flutter, no SQL. |
| `lib/data/` | `local/` (sqflite + migration ledger), `datasources/` (one local and one remote per aggregate), `models/`, `repositories/`. |
| `lib/services/` | Sync, reminders, dose maintenance, export, backup, photos, AIFA cache, connectivity, biometrics, updates. |
| `lib/presentation/` | Riverpod providers, go_router routes, screens and widgets. |
| `lib/l10n/` | `app_en.arb`/`app_de.arb`/`app_it.arb` plus generated delegates. |

## Provider layout

`providers.dart` is the wiring file — datasources, repositories, services,
startup tasks. Around it are two kinds of file.

**Leaves** never import `providers.dart`, so anything that needs one of them
can be tested without standing up the wiring: `now_provider.dart`
(`nowProvider`, the one clock seam, alone because nearly every screen needs it
and nothing else), `settings_providers.dart` (prefs, theme/locale/colour,
reminders, biometrics, grace period, `BuildInfo`, cloud credentials, the
connection probe), `app_config_`, `app_mode_`, `sync_`, `auth_`,
`onboarding_` and `app_update_provider.dart`.

**Aggregate files** — `dose_`, `medication_`, `treatment_`, `family_` and
`prescription_providers.dart` — do import `providers.dart`, for the
repositories they build their lists and actions on, and `providers.dart`
imports several of them back for the startup tasks. That mutual import is
accepted: Dart resolves it, and the alternative is a third file that does
nothing but hold the repository providers. What is not accepted is a leaf
growing an import of `providers.dart` — that is the edge the layering
depends on.

## App modes

`AppMode { localOnly, cloud }` is persisted in `SharedPreferences`; cloud mode
also needs usable credentials. `SupabaseConfig.resolve` picks them **Settings >
dart-defines > none** — a pair entered in Settings (`cloud.supabase_url`,
`cloud.supabase_anon_key`) beats the `SUPABASE_URL`/`SUPABASE_ANON_KEY` baked
into the build — and without either the remote datasources are never built.
`Supabase.initialize` runs once per process, so credentials saved while it is
already running set `pendingRestart`; the anon key lives only in
`SharedPreferences`, is never logged and never shown again. Repositories always
write locally first — local-only is the base case, not a degraded mode — and
`debugSetConfiguredForTest` flips `isConfigured` without creating a client, so
widget tests can render a configured build.

## Local data: schema, backup and restore

`lib/data/local/migrations.dart` is an append-only ledger of `Migration`
(version + function); `kSchemaVersion` is **15** and must equal the last entry,
and existing migrations are never edited: v11 added tombstone columns, v12 bare
photo filenames, v13 naive-local dose timestamps so string ranges line up with
local day boundaries, v14 the medication EAN, v15 the sick-leave columns
(`sick_leave_from`, `sick_leave_to`, `sick_leave_ref`, `doctor`) on
`treatments`, all nullable. `BackupService` writes the database and photo folder into one versioned JSON
envelope (`format: "medora-backup"`, `version`, `schemaVersion`, `createdAt`,
`appVersion`, `tables`, base64 `photos`); rows go out exactly as stored, minus
`sync_status`. `inspect` validates it first, so a backup from a newer build is
refused rather than half-applied, and `restore` applies the file in one
transaction in foreign-key order: one that cannot be applied in full leaves the
device as it was. `replace` clears the tables first; `merge`
upserts by id, and the backup must be **strictly** newer by `updated_at` to win.
Restored rows are stamped `synced`, or `pending_update` under `markPending`
(cloud) — except `family_members`, since RLS only accepts the user's own row.
Settings covers the run with an un-dismissable "Restoring…" dialog, then resets
the reminders and invalidates the caches. The whole envelope is held in memory,
so the export unticks photos above `largePhotoBytes` (150 MB).

## Reminders, doses and expiry

`ReminderScheduler` is the single owner of "which notifications exist": each
`reconcile` loads the pending doses inside a **7-day** horizon, earliest first,
capped at **60** platform notifications — **2** per dose, so **30** doses — and
after the first run applies only the delta against the previous snapshot of id +
scheduled time, so a dose whose time moved is re-scheduled.
`DoseMaintenanceService.markOverdueAsMissed` flips pending doses older than a
grace period to *missed* (**120 min** by default, from 30/60/120/240).
Expiry is a **date**, so comparisons round to whole calendar days through
`calendarDaysBetween`: a medication stamped "expires today" is good for all of
today, `expiredAt(now)` is true only once `daysUntilExpiry` goes negative — the
rule `ExpiryBadge` and the Home countdown already used — and `isExpiringSoon` is
the 30-day window before it.

## Scanner

`BarcodeScannerScreen` (`/scanner`, `?returnOnly=true` pops with the chosen
code) runs `capture → recognizing → review`. Capture shows the camera preview
(no image stream) with a shutter, gallery import and manual entry. The still
photo goes to ML Kit once: the text recogniser and the barcode scanner run in
parallel on the same `InputImage.fromFilePath`. `ocr_adapter.dart` and
`barcode_adapter.dart` are the only ML Kit mappings; the pure
`findCodeCandidates` ranks AIC, supplement, EAN and other codes and merges the
decoded barcodes. `ScanReviewView` shows the photo with numbered markers and
the same list. Selecting routes by kind: AIC → AIFA cache search (result
picker → Add Medication), supplement → Add Medication prefilled, EAN → the
cabinet medication with that barcode (else Add Medication), other → Add
Medication prefilled; leaving replaces the scanner route (`pushReplacement`).
Add Medication always opens the scanner return-only. Camera photos are
temporary files deleted on retake, on leaving the screen and in `dispose`; a
gallery pick is deleted the same way only when it is the picker's copy inside
the app's temporary directory, never a user's original. The image size for
the review comes from the encoded header (`ImageDescriptor`, EXIF-upright),
not a full decode.

Food-supplement codes resolve through `SupplementRegistryService`
(`supplementRegistryServiceProvider`; `http.Client`, `openDatabase` and `now`
seams). It downloads `integratori.csv.gz` and `integratori.meta.json` from the
GitHub pre-release `data-integratori` (built monthly from the Ministry of
Health PDF by `tools/build_supplements_data.py`, see `docs/release.md`),
gunzips and parses the CSV off the UI isolate (`compute`) and replaces the
`supplements` table of its own `supplement_cache.db` in one transaction, so a
failed download keeps the previous data. Count, last download and the
register's `sourceUpdated` date live in shared preferences. `findByCode`
matches digits without leading zeros. Selecting a supplement candidate offers
the first download (online), then `supplementRouteFor` decides: one match →
Add Medication prefilled with a `SupplementEntry` extra (name, manufacturer,
category `supplement`, barcode), several → a picker, none → Add Medication
with the code. The feature is gated by
`PlatformCapabilities.hasSupplementRegister` (not on web).

## In-app updates (Android)

`AppUpdateService` is pure Dart over `package:http`: read `/releases/latest` for
`AppConfig.updateRepo`, compare the tag with the running build, pick the APK for
the device's ABI (else universal), stream it into `<support dir>/updates/` while
hashing, verify size and `SHA256SUMS.txt`, hand it over — any failure deletes
the partial file. `AppUpdateNotifier` owns the states (`Unknown →
Checking → Available → Downloading → Ready`) and the gates: Android, a configured
repo, a connection, a 24 h throttle. **Cancelling:** `download` takes
an `isCancelled` seam asked once per chunk. Each download holds a generation
number; `cancelDownload()` burns it and puts the state back to
`UpdateAvailable`, and a download whose generation is spent — cancelled, or
replaced by a newer one — reports nothing and keeps no APK, so a re-download
started while the first is still unwinding is the only one that can reach the
state. **Installing:** Android never reports back, so `install()` writes the
tag first (`update.installing_tag`) and the next `build()`/`check()` settles
it — running this release means it worked (`clearDownloads`, pref cleared),
otherwise the APK still on disk becomes `UpdateReady` and Install, explained
beforehand because Android asks to allow installs, is offered again. That tag
records one opened installer, not a verdict: a `check` still asks GitHub, and
a release newer than the pending APK clears both the pref and the file and is
offered as usual — as does "Later" on it. Only a check that finds nothing
newer, is throttled, or cannot run at all leaves the pending install standing.

## Sync

`SyncService` runs a cycle as push, then pull. **Push** uploads pending rows; one
that throws becomes a `SyncFailure` and the batch continues, and a row that keeps
failing is skipped until `min(2^count minutes, 6 h)` after its last attempt.
**Pull** is a delta per table: only rows newer than the stored cursor, tombstones
(`deleted_at`) applied as hard local deletes. A hosted project answers at most
**1000** rows per request, so the rows come in pages of 1000, ordered by
`updated_at` then `id`, each page starting after the last row of the one before
(keyset paging), until a short page, and at most **50** pages per table per
cycle. After each page the cursor moves to that page's last `updated_at` minus
**1 second** of overlap, unless a row of this pull failed to apply; so a failure
part-way leaves it at the end of the last fully stored page. Once a pull has
read to the end, the cursor never sits before `1970-01-02`. Builds before the
paged pull read newest first and so moved their cursors past rows they never
received; the first cycle that runs after the upgrade (cloud mode, online,
signed in) therefore clears every table's cursor once and pulls everything
again with the usual merge rules, without wiping or pushing anything. The
`sync.pull_repair.reset` and `sync.pull_repair.done` preferences record that
per repair version; `done` is set only once a cycle fetched every table, and a
later cycle carries on from the cursors the pages stored. **Conflicts**
resolve **last write wins by `updated_at`** on both sides: the push reads the
remote value first and leaves a row it would clobber for the pull to overwrite,
while the pull keeps a locally pending row at least as new as the remote copy
and never resurrects a row a local tombstone has deleted. The server stamps
every update with its own clock, so of two explicit changes the one that
reaches the server last wins, whenever it was made. An insert keeps the
client's stamp, so a push whose answer carries the stamp it sent (a row
created offline) is sent once more to take the server's, and devices that
synced meanwhile still pull it. `forcePush` skips that comparison; **force pull**
wipes local rows and re-downloads, aborting if a table cannot be fetched
afterwards. Families are pulled separately, through the `join_family`
security-definer RPC. **Doses** created on a device (a generated schedule, a
logged dose) are inserted only where the server lacks their id, **100** per
request, then read back and stored as synced, so a dose taken elsewhere is never
replaced; a batch the server refuses is sent again row by row, and the doses of
a prescription the server refused wait for it. A generated dose is stamped
`1970-01-01` and no delta pull brings it, so every device generates its own
copies under the same ids (`dose_slot.dart`, from the prescription's wall-clock
`start_time`): `DoseScheduleService` regenerates a prescription a pull stored
as new or rescheduled, and on start, resume and after every sync it
regenerates any running prescription whose stored doses differ from its
scheduled times. Marking an overdue dose *missed* is a local conclusion: its
stamp moves just past the previous one and nothing is queued, so any real
change pulled later wins; a dose with an unpushed change is left for later. On
start and resume the sync runs before that marking. Every request has a **30 s** timeout and fails
like a network error. Each cycle fills a `SyncReport` that Settings renders,
offering `discardFailedRow` per failed row; auto-sync fires **2 s** after
connectivity returns, and a mid-cycle `syncAll()` is queued, up to **3**
re-runs; a sync stopped there retries once **15 s** later. Schema, RLS and
triggers live in `supabase/migrations/`.

## Prescriptions (Rx)

The entity is `Rx` (the existing `Prescription` is the dosing plan of a
treatment). Three synced tables, local and server
(`supabase/migrations/20260923000000_rx.sql`): `persons` (who a prescription
is for, with tax code and exemptions), `rx` (the document: kind, NRE, dates,
doctor, priority, its items) and `rx_dispensings` (one row per pickup at the
pharmacy). They carry the sync v2 columns, stamp trigger and owner-only
row-level security of the other tables, and back-ups and "delete all data"
include them.

- **Soft references.** `rx.person_id`, `rx.treatment_id` and the medication
  an item names have no foreign key, locally or on the server: deleting a
  person, a treatment or a medication never deletes a prescription, and
  `rx` stays a root table for sync, with no orphans to handle. The UI shows
  a missing reference as unknown.
- **One sync child.** `rx_dispensings` is the only child: its `rx_id` is a
  real foreign key, an `rx` tombstone cascades to its dispensings
  (`cascade_tombstone_rx`), and a live dispensing sent under a deleted
  prescription is stored deleted by the `rx_dispensings_sync_stamp_parent`
  trigger, as the app's own change (1970 edit time). That trigger's name
  sorts between `_sync_stamp` and `_updated_at` on purpose, since BEFORE
  triggers fire in name order. The row-level security checks the parent on
  insert and update, so a dispensing can only ever name its owner's
  prescription.
- **Items as one JSON column.** `rx.items` is a JSON list (`jsonb` on the
  server, text locally) and merges as a whole, like any other column: two
  devices editing different items of one prescription keep the later edit,
  not both. Items are edited rarely and together with their prescription;
  only dispensings need a row per event, so two devices redeeming at the
  same time never lose one to a whole-row last-write-wins.
- **Reminders.** Expiry reminders for open prescriptions (three days before
  the last valid day, then the day itself; one booked at a time) share the
  stock scheduler: same hour, same 16-slot id block per id, offset **10**
  (`0xA`, after expiry `0x8` and low stock `0x9`), payload `rx:<id>` which
  opens the prescription.
- **Pharmacy view.** `PharmacyScreen` shows the barcodes the paper itself
  carries, as Code 128 (`code128.dart`, drawn without a library, with the
  same start/checksum/stop as the print) for the pharmacist to scan off the
  screen: an SSN/referral NRE as its two printed halves (5 then 10
  characters, `Nre.split`), a white NRBE followed by its PIN when set, then
  the person's tax code when known (`pharmacyCodesFor`). It does not raise
  the screen brightness yet: that needs a plugin.

### Scanning

Adding a prescription can start from a scan instead of a blank form, but
scanning is offered only where an on-device reader exists —
`PlatformCapabilities.hasOnDeviceScanner`, true on Android and iOS only:
`showAddRxSheet` (`rx_scan_sheet.dart`) then offers a camera photo (also
needs `hasCamera`), a gallery photo or a PDF/image file. Everywhere else
(desktop, web) the add action goes straight to the manual form — there is
no reader to make a scan worthwhile even where a file can still be picked.

Pipeline: picker → `RxScanService` → `RxExtractor` → `RxDraft` → the form,
prefilled with hints → save, with the original attached.

- **RxScanService** (`lib/services/rx_scan_service.dart`) reads a photo or a
  PDF. A photo is tried at the four right-angle rotations (0/90/180/270°),
  since a barcode may be printed sideways; the loop stops early once the
  barcodes decoded so far already give an NRE/NRBE and a tax code, and text
  recognition then runs once, on the rotation that decoded the most
  barcodes. A PDF's own text layer is used as-is when it has one; only a PDF
  with no text layer at all is rasterized (page 1, via `pdfrx`/PDFium) and
  OCR'd — barcodes are always read off that rendered first page. Every scan
  works in its own directory under `<temp>/rx_scan/<scan>/`, deleted when
  the scan ends and swept by the next scan if still there past 10 minutes
  (`kRxScanDirMaxAge`), never in the shared temp root, so a late write from
  a timed-out pass cannot land somewhere still in use. A file over 20 MB or
  60 MP, or a read that fails outright, ends in `RxScanResult.failed` (the
  size refusals also set `refusal: ImportRefusal.tooLarge`, which the sheet
  shows before opening anything) rather than throwing: a scan is a
  convenience, never a hard requirement.
- **RxExtractor** (`lib/domain/rx/rx_extractor.dart`) turns decoded barcodes
  and recognised text into an `RxDraft`. Barcodes are trusted; text is only
  ever a suggestion the user checks in the form (`RxDraft.fromBarcode` marks
  which fields came from a barcode, for the `rxFromScan` hint). The
  NRE/NRBE is never read from text, only from a barcode: a misread digit
  there would send the user to the pharmacy with a wrong number.
  - **Barcode classes.** An SSN/referral NRE prints as two barcodes, 5 then
    10 characters (`Nre.split`); a white electronic NRBE is one
    12-character barcode, with its 5-character PIN printed (and barcoded)
    under it; a person's tax code (codice fiscale) is a 16-character
    barcode, one for the patient and, on some layouts, another for the
    doctor.
  - **Patient vs. doctor tax code.** A code matching a person already on
    the device is the patient; failing that, a text label naming exactly
    one code decides; failing both, order decides (the first candidate is
    the patient, the next the doctor) and that guess is never marked
    barcode-trusted.
- **Privacy.** Everything runs on the device: no network OCR, nothing
  scanned is ever sent anywhere. The picked photo/PDF is attached to the
  prescription once saved (see Attachments below); the intermediate
  rotation/rasterized images used only to decode it live in the scan's own
  temp directory and are gone within 10 minutes even if the scan is
  interrupted.
- **Platforms.** Android and iOS only; see `hasOnDeviceScanner` above.

### Attachments

Photos and PDFs attached to a prescription (the model also allows a
treatment or a person as the owner; the UI offers prescriptions only).

- **Row and bytes.** The `attachments` row (local migration 18, server
  `supabase/migrations/20260924000000_attachments.sql`) holds the metadata
  (owner, kind, MIME type, size, sha256, `remote_path`) and syncs like every
  other table. The bytes live in `<documents>/attachments/<id>.<ext>`
  (`AttachmentFiles`; written as `<name>.part` and renamed, so a file is
  never seen half-written) and in the private storage bucket `attachments`.
  Contents never change: a changed file is a new attachment.
- **A prescription's attachments are its children.** An attachment with
  `owner_kind = 'rx'` is treated like a dispensing: `parentsOf` names its
  `rx`, so a pulled one waits for (or is passed over with) its
  prescription, and a pending one under a prescription deleted here is
  dropped unsent. The server stores a live one under a deleted
  prescription deleted (`attachments_sync_stamp_parent`, sorting between
  `_sync_stamp` and `_updated_at`), and an `rx` tombstone cascades to them
  (`rx_tombstone_cascade_attachments`). There is no local foreign key, so
  applying a pulled `rx` tombstone (or discarding an `rx` the server has
  deleted) deletes its attachment rows in the same transaction
  (`TableSync.deleteRxAttachmentsIn`). Whenever the sync deletes an
  attachment row here (a tombstone, a parent's delete, a push stored
  deleted), its object is queued for removal if it lies in the signed-in
  account's folder, since a delete the server made is queued by no one
  else; the files go with the sweep. Attachments of treatments and persons
  are not tied to their owner.
- **Path.** `<auth.uid>/<id>.jpg` or `.pdf`. The server checks it: an id
  never holds `/`, the path must be the owner's folder plus this id and the
  kind's extension, and a photo is always `image/jpeg`, a PDF always
  `application/pdf`. Storage policies let an account read, add and remove
  objects in its own folder only; there is no update policy, no public URL
  and no signed URL.
- **Transfer order.** `AttachmentTransfer.run()` (after each sync that ends
  in success or partial; calls during a pass fold into one more pass) first
  removes the queued objects of deleted attachments (`attachment_removals`,
  100 per request, only paths in the signed-in user's folder), then uploads
  the files of rows without a `remote_path` and records the path, which the
  next sync pushes, then sweeps. Failures back off per item (1 min, 5 min,
  30 min, then 2 h). Recording refuses a path outside the row's owner's
  folder (or, for a row cleared by an account change, the signed-in user's)
  and queues that object for removal instead. Downloads happen on demand
  when an attachment is opened, and a download whose size or SHA-256
  differs from the row's is thrown away.
- **Sweep.** Local files with no row at all go, except those written in the
  last five minutes (an `add` that has written its file but not its row).
  It also runs on its own after "delete all data" on another device removed
  attachment rows here.
- **Import.** A photo is decoded, turned upright (the EXIF orientation is
  baked into the pixels), scaled to at most 2400 px on the long edge and
  re-encoded as JPEG quality 85, which drops every EXIF field (location,
  camera). A PDF is stored unchanged, up to 20 MB; any other type is
  refused. The bucket enforces the same 20 MB and the two MIME types.
- **Backups and wipes.** A backup carries the rows under `attachments` and,
  with the photos, the files of live attachments under `attachmentFiles`;
  without the photos a restored attachment is downloaded again when opened
  (or shows "not available" if it was never uploaded). "Delete all data"
  removes the rows in `medora_delete_all_data` and then the user's storage
  folder from the client, because SQL cannot delete storage objects
  (`storage.protect_delete()`); the local wipe deletes the folder of files.
  A device that follows a wipe made elsewhere removes its attachment rows
  from before it (and those of removed prescriptions) and queues their
  objects in its own folder for removal, since it may have uploaded after
  the folder went. The web build has no file system: it lists attachments
  but offers no add button and no local thumbnails.
  A restored backup's rows keep the backing-up account's owner and path;
  when a different account then signs in (or the first one after a restore
  in local mode), `LocalUploadMarker.markAllForUpload` clears the owner and
  path of every attachment row of another account, so its file is uploaded
  again into the signed-in folder instead of being refused by the server
  forever. A backup's `attachmentFiles` may only name `<id>.jpg` or
  `<id>.pdf` of its own attachment rows (extension by kind); any other name
  makes it corrupt before anything is written. A restored live attachment
  whose file is on the device forgets its path, so the transfer uploads it
  again (its object may be gone after "delete all data"; one still there
  counts as done); a restored one without its file keeps its path. A
  queued removal of a restored live row's path is dropped, so it cannot
  delete the object under the restored attachment.
- **Force pull.** When the server has no `attachments` table yet, a force
  pull keeps the local `attachments` rows and `attachment_removals`: the
  pull could never bring them back. Otherwise it clears both with the other
  tables and pulls the rows again. Objects that were queued for removal then
  stay in the bucket until the next "delete all data" removes the folder.
  That is deliberate: the force pull may bring back a row whose object is
  in the queue, and removing the queued object would leave that row without
  its file.

## Theme and localization rules

Colors come from the Material 3 scheme plus the `MedoraColors` theme extension
(`lib/core/theme_extensions.dart`), reached via `context.medora`. Three sweeps
keep this from eroding: `theme_sweep_test.dart` fails on any `Colors.*` (except
`transparent`/`black`) or legacy `AppTheme.*Color` under `lib/presentation`;
`l10n_sweep_test.dart` on a capitalised literal in a `Text`/`label`/`title`/
`tooltip` position under `lib/presentation` or `lib/services` without `l10n.` or
`// l10n-exempt`; `clock_sweep_test.dart` on `DateTime.now()` outside
`lib/core/clock.dart`. Every semantic colour pair clears 3.0 contrast in both
themes, every string exists in all three ARBs, and the committed `gen-l10n`
output must not drift from the ARBs.

## Testing layout

`test/core|domain|data|services` hold unit tests over an in-memory sqflite
database (`test/helpers/test_database.dart`) and fake remotes;
`test/presentation` the widget tests and the three sweeps; `test/goldens` Home,
add-medication and doses (twice: an ordinary day and the two-due "Take all due"
bar) in light and dark, regenerated deliberately with `fvm flutter test
--update-goldens test/goldens/`; `test/integration` the two-device convergence
test, skipped without the `SUPABASE_URL`/`SUPABASE_ANON_KEY` defines. CI
(`.github/workflows/ci.yml`) runs the gen-l10n drift check, `dart format`,
`flutter analyze --fatal-infos` and the tests, then builds web and an Android
APK. The integration tests live in their own reusable workflow
(`.github/workflows/integration.yml`): manual, label-triggered on a pull
request, and a gate `release.yml` waits for, so the tag build cannot publish
ahead of them.
