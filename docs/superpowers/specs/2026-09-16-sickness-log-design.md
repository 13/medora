# Sickness log — illness episodes with sick leave (Krankenstand) — design

**Date:** 2026-09-16. **Status:** proposed. Branch base: `dashboard-fixes` (v0.2.4+16).
Open questions for the user in §12; everything else is decided.

## 1. What the user asked for

> "log when i was sick — for example Stirnhöhlenentzündung, i was in Krankenstand
> (not working) from date to date, i took ibuprofen and so on"

In plain terms, one record per illness episode holding: what it was, the days it
lasted, the **separate** period of certified inability to work, which medicines
were taken and how, who the doctor was, and free notes on how it went. The user
is in Italy, writes German, and uses the app for their own household; "Krankenstand"
is Austrian/German for certified sick leave. In Italy the equivalent is a
*certificato di malattia* with a *numero di protocollo*, which is the number an
employer actually asks for.

## 2. What the codebase already has

### 2.1 `Treatment` is already an illness episode, not a therapy plan

`lib/domain/entities/treatment.dart` opens with *"Core domain entity representing
an **illness**/treatment plan"* and carries exactly the episode fields:

| Field | Type | Already does |
|---|---|---|
| `name` | `String` | The illness ("Influenza" in the golden fixture; hint "z.B. Grippebehandlung") |
| `symptomTags` | `List<String>` | Symptoms, via `TagInputField` |
| `patientTags` | `List<String>` | Who was ill |
| `startDate` / `endDate` | `DateTime` / `DateTime?` | Illness period |
| `isActive` | `bool` | Open vs. recovered |
| `notes` | `String?` | Free text |
| `durationDays` | getter | `endDate - startDate` |

The German strings agree: `createTreatmentPlan` = *"Erstellen Sie einen
Behandlungsplan für eine **Erkrankung**"*. The golden fixture
(`test/goldens/golden_config.dart`) is a treatment named `Influenza` with
`symptomTags: ['fever', 'cough']`. The feature the user wants is 80 % built; what
is missing is the **sick-leave period**, the **doctor**, and an honest way to
record medicines taken **without a schedule**.

### 2.2 Medications, doses and schedules

`Treatment 1─n Prescription 1─n DoseLog`, FK-cascaded in SQLite and mirrored in
Supabase. `Prescription` (`lib/domain/entities/prescription.dart`) holds
`medicationId`, `dosageAmount` + `dosageUnit` (plus legacy free-text `dosage`),
`scheduleType` (`'fixed_interval'` | `'times_per_day'`), `intervalHours`,
`scheduleTimes` (`['08:00','14:00','20:00']`), `durationDays`, `startTime`, and
generates its own dose rows via `scheduledDoseTimes`. So *"ibuprofen 400, three
times a day, five days"* is already expressible **exactly**: one prescription,
`scheduleType: 'times_per_day'`, three times, `durationDays: 5` — and the fifteen
`dose_logs` rows it generates are the real, timestamped intake record
(`status`: pending/taken/skipped/missed, `takenTime`).

`DoseLogLocalDatasource._joinQuery` already joins dose → prescription → treatment
→ medication and exposes `treatment_name`, `medication_name`, `dosage_amount`,
`dosage_unit`. Everything needed to *derive* "what I took during this episode"
is one `WHERE p.treatment_id = ?` away.

### 2.3 Local schema and migrations

`lib/data/local/migrations.dart` is an append-only list; `kSchemaVersion` is
**14** (v11 tombstones, v12 bare photo filenames, v13 naive-local dose
timestamps, v14 `medications.ean`). `AppDatabase` keeps a `schema_migrations`
ledger and back-fills it on upgrade. **The next migration number is 15.**
(`docs/architecture.md` still says 13 — stale; fix it to 15 with this work.)

### 2.4 Backup

`BackupService` (`lib/services/backup_service.dart`) copies whole rows verbatim
(`db.query(table)` minus `sync_status`) into a versioned JSON envelope and
restores them column-by-column inside one transaction. **Adding columns to an
existing table therefore needs no backup change at all**: new columns ride along
automatically, a v14 backup restored on v15 leaves them null, and a v15 backup
opened by a v14 build is refused up front by the `schemaVersion > kSchemaVersion`
check. A *new table* would instead require edits to `tables`, `_insertOrder`,
`_versioned` and `LocalUploadMarker.tables`. This is a real argument for columns.

### 2.5 Supabase sync

`TreatmentModel.toJson()` is uploaded **as a whole row**, so any new column must
exist server-side *before* a v15 client syncs — the same note
`supabase/migrations/20260916000000_medication_ean.sql` carries. RLS on
`treatments` is `user_id = auth.uid()`; prescriptions and dose logs inherit
through the treatment. Tombstone cascade triggers already exist. New *columns*
need no policy, trigger or `SyncService` change; a new *table* would need all
three plus a local/remote datasource pair wired into `SyncService`'s ten
constructor arguments.

### 2.6 Localisation

Three ARBs (`lib/l10n/app_{en,de,it}.arb`, template = en), `nullable-getter:
false`, CI checks gen-l10n drift, and `test/presentation/l10n_sweep_test.dart`
fails on any capitalised literal in a `Text`/`title`/`label`/`tooltip` position
without `l10n.` or `// l10n-exempt`. German register is mixed by area: the
treatment/medication forms and dialogs use formal *Sie* ("Bitte geben Sie…",
"Möchten Sie…"), while onboarding and update strings use *du*. Vocabulary is
fixed: **Behandlungen, Medikamente, Dosen, Verschreibungen, Symptome**. New
strings in the treatment area stay with the nouns and, where a sentence is
needed, with *Sie*.

### 2.7 UI patterns

List (`treatment_list_screen.dart`): `AppBar` search toggle, three `FilterChip`s
(Aktiv/Beendet/Alle), `Slidable` rows with End + Delete, `EmptyStateWidget`, FAB.
Detail (`treatment_detail_screen.dart`): status chip, `TagChip` rows, start/end
`DetailRow`s (`endDate.formattedOr(l10n.ongoing)`), notes, then the prescription
list with an "Add" button. Forms: full screen for the treatment
(`add_treatment_screen.dart`), **modal bottom sheet** for the prescription
(`showPrescriptionSheet`). Reusable: `FormSection` (collapsible card with a
collapsed summary), `DatePickerField`, `TagInputField`, `DetailRow`, `TagChip`.

### 2.8 The Home golden constraint

`test/goldens/home_golden_test.dart` asserts `maxScrollExtent == 0` at 964 dp:
**any new Home section breaks the goldens.** Another agent is editing
`home_screen.dart` and the Home goldens right now. This design therefore adds
**no** Home section — see §6.6.

## 3. Decision: extend `Treatment`; do not add a parallel entity

| Option | Verdict |
|---|---|
| **A. New `SicknessEpisode` entity + table** | **No.** Duplicates name/symptoms/dates/notes; needs its own medication link (either a second prescription-like table or an episode↔treatment join), a new local+remote datasource pair, `SyncService` wiring, RLS, tombstone triggers, backup table lists — and forces the user to choose between two illness-shaped things every time they get sick. |
| **B. Rename `Treatment` → `SicknessEpisode`** | **No.** The domain concept is right, the name is only half right; a rename touches ~40 files, the SQLite table, the Supabase table, the backup envelope key, the sync cursors and 30+ l10n keys in three languages — pure churn, zero user-visible gain, and it would collide with the Home work in flight. |
| **C. Extend `Treatment` with the sick-leave fields** | **Yes.** Four nullable columns, one local migration, one Supabase migration, no backup change, no sync change, no new screens. A treatment *is* the episode; the sick leave is a property of it. |

Consequence: "Behandlungen" keeps covering both an illness episode and an
ongoing therapy (a vitamin course has no sick leave and simply leaves the fields
empty). The illness identity shows up where it matters — a **Krankenstand**
field group in the form, a badge in the list, a block in the detail — not as a
second tab.

**The illness name is `name`.** No separate `diagnosis` column: the user types
"Stirnhöhlenentzündung" (or "Sinusitis frontalis") in the one name field, and
`symptomTags` + `notes` carry the rest. A second near-identical text field would
be answered inconsistently and then need reconciling in every export.

## 4. Data model

### 4.1 New fields — `Treatment` and `TreatmentModel`

```dart
final DateTime? sickLeaveFrom;  // date only: first day unable to work
final DateTime? sickLeaveTo;    // date only: last day; null while ongoing
final String?   sickLeaveRef;   // certificate / protocol number (IT: numero di protocollo)
final String?   doctor;         // free text: "Dr. Rossi, Bolzano"
```

All nullable, all added to the constructor (with no defaults), the field list,
`copyWith`, and to `TreatmentModel`'s `fromJson` / `fromLocalMap` / `toJson` /
`toDomain` / `fromDomain`. Dates serialise like `start_date`/`end_date`:
`toIso8601String().split('T').first`, parsed with `DateTime.tryParse`.

Deliberately **not** added: `sickLeaveEmployer`, a certificate photo, an outcome
enum, a severity scale (§11).

### 4.2 Derived getters (entity, unit-tested, clock injected)

```dart
bool get hasSickLeave    => sickLeaveFrom != null;
bool get isSickLeaveOpen => sickLeaveFrom != null && sickLeaveTo == null;

/// Inclusive calendar days of sick leave; null when none is recorded.
/// An open leave counts up to [now].
int? sickLeaveDaysAt(DateTime now) => sickLeaveFrom == null
    ? null
    : calendarDaysBetween(sickLeaveFrom!, sickLeaveTo ?? now) + 1;
```

`calendarDaysBetween` (`lib/core/clock.dart`) re-anchors to UTC midnight, so a
DST change inside the range cannot shave a day. Inclusive (+1) because a sick
note "from Mon to Fri" means five days, not four. No `DateTime.now()` anywhere —
`clock_sweep_test.dart` enforces that.

### 4.3 Local migration — **v15** (next free number)

```dart
// v15: sick leave (Krankenstand) on an illness episode: the days unable to
// work, which need not equal the illness period, plus the certificate number
// and the doctor.
Migration(15, (db) async {
  await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_from TEXT');
  await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_to TEXT');
  await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_ref TEXT');
  await db.execute('ALTER TABLE treatments ADD COLUMN doctor TEXT');
}),
```

plus `kSchemaVersion = 15`. No index: the list screen already loads every
treatment row and filters in Dart.

### 4.4 Supabase migration — `supabase/migrations/20260917000000_treatment_sick_leave.sql`

```sql
-- Medora: sick leave (Krankenstand) on a treatment. The treatment remote
-- datasource uploads TreatmentModel.toJson() as a whole row, so these columns
-- must exist before a client on schema v15 syncs.
alter table if exists public.treatments
  add column if not exists sick_leave_from date,
  add column if not exists sick_leave_to   date,
  add column if not exists sick_leave_ref  text,
  add column if not exists doctor          text;
```

(Timestamp is one day after `20260916000000_medication_ean.sql`, which is today's
newest.) No RLS change — `treatments_*` policies are already `user_id =
auth.uid()`. No trigger change — the tombstone cascade is per-row, not per-column.

### 4.5 Touch-point checklist

| File | Change |
|---|---|
| `lib/domain/entities/treatment.dart` | 4 fields, ctor, `copyWith`, 2 getters |
| `lib/data/models/treatment_model.dart` | 4 fields in ctor + 5 mapping functions |
| `lib/data/datasources/treatment_local_datasource.dart` | `_fromRow` / `_toRow` |
| `lib/data/local/migrations.dart` | Migration 15, `kSchemaVersion = 15` |
| `supabase/migrations/2026091700…sql` | new file |
| `lib/data/repositories/treatment_repository_impl.dart` | **`endTreatment` rebuilds the model field-by-field instead of using `copyWith` — it will silently drop the four new fields on every "end". Switch it to `existing.copyWith(...)`.** This is the one real regression risk in the change. |
| `lib/services/backup_service.dart` | **none** (verbatim rows) |
| `lib/services/sync_service.dart`, `local_upload_marker.dart` | **none** (same table) |
| `lib/services/export_service.dart` | optional extra CSV columns; §7 |

## 5. How medications attach

### 5.1 Scheduled intake — unchanged

The episode's medicines are its `Prescription` rows and the `dose_logs` they
generate. Nothing is retyped: the medication comes from the cabinet, the dose
history is the tick-off record the user already produces day by day.

### 5.2 The medication list is derived, never typed

New read, following the existing join:

```dart
// DoseLogLocalDatasource
Future<List<DoseLogModel>> getDoseLogsByTreatment(String treatmentId) =>
  // '$_joinQuery WHERE p.treatment_id = ? AND d.sync_status != ? ORDER BY d.scheduled_time ASC'
```

→ `DoseLogRepository.getDoseLogsByTreatment` → `doseLogsByTreatmentProvider`
(`FutureProvider.family<List<DoseLog>, String>` in `dose_providers.dart`, watching
`doseDataVersionProvider` like `dosesForDayProvider` does). The treatment detail
then shows, per prescription, *"12 von 15 eingenommen"*, and the export (§7)
reads the same source. One query, three consumers, zero duplicated data entry.

### 5.3 Medicines taken **without** a schedule — `schedule_type = 'as_needed'`

The honest gap: half of a real illness is "I took one ibuprofen at 3 p.m. because
it hurt". Today that can only be recorded by inventing a schedule.

**Design:** a third `scheduleType`, `'as_needed'` (*bei Bedarf* / *al bisogno*),
which generates **no** doses:

- `Prescription.scheduledDoseTimes` returns `[]` for it; `dosesPerDay` returns 0;
  `previewTimes()` is empty. `intervalHours`/`durationDays` keep their NOT NULL
  defaults and are hidden in the sheet.
- The prescription sheet gets a third schedule chip; choosing it hides the
  interval/times controls.
- The treatment detail shows **"Dosis eintragen"** on an as-needed prescription,
  which inserts one `DoseLog` with `status: taken`, `scheduledTime = takenTime =
  now` (via `nowProvider`), through the existing `addDoseLog` +
  auto-diminish/stock path.
- Reminders are unaffected: `ReminderScheduler` only ever looks at *pending*
  doses, and an as-needed prescription never has any.

Cost: one string constant, three small branches, no migration (`schedule_type`
is a free-text column with a default), no new table, no RLS hole — the dose still
hangs off a prescription, which is what the `dose_logs` RLS policy walks up to
find the owner. Rejected alternative: making `dose_logs.prescription_id`
nullable and hanging ad-hoc doses directly off a treatment — that breaks the FK,
the RLS policy and `_joinQuery`'s display fields, for the same user outcome.

## 6. Screens and flows

### 6.1 Creating an episode while ill

`AddTreatmentScreen` (`/treatments/add`, FAB on the Behandlungen tab and the
"Neue Behandlung" quick action on Home) keeps its current fields and gains **one
collapsible `FormSection`** below the notes:

> **Krankenstand** (icon `Icons.work_off`, `initiallyExpanded: false`,
> `summary:` the formatted range once set)
> - `DatePickerField` — *Arbeitsunfähig von* → `sickLeaveFrom`
> - `DatePickerField` — *Arbeitsunfähig bis* (optional; `firstDate: sickLeaveFrom`) → `sickLeaveTo`
> - `TextFormField` — *Bescheinigungsnummer* → `sickLeaveRef`
> - `TextFormField` — *Ärztin/Arzt* (icon `Icons.medical_services`) → `doctor`

Collapsed by default, so a user logging an ordinary therapy sees the form they
have today. Validation: `sickLeaveTo` may not precede `sickLeaveFrom`; a `to`
without a `from` is rejected with the existing inline-error style. Note that
while the screen is open the form is a plain `ListView` — the section slots in
without restructuring it.

The medicines are added afterwards, from the detail screen, exactly as today
(scheduled via the prescription sheet, ad hoc via §5.3).

### 6.2 Closing it when recovered

The existing **End** action (slidable row and detail app bar) already sets
`isActive = false, endDate = today`. Change: when the treatment has an open sick
leave (`isSickLeaveOpen`), the confirm dialog gains one checkbox —
*"Krankenstand ebenfalls heute beenden"*, ticked by default — and
`endTreatment` then also writes `sickLeaveTo = today`. When there is no sick
leave, the dialog is exactly what it is today. (This is where the
`copyWith` fix from §4.5 is load-bearing.)

### 6.3 Editing later

`/treatments/:id/edit` already re-opens the same form; the new section opens
pre-expanded when it has data (`FormSection.controller`, the pattern
`add_medication_screen` uses). Nothing else needed — a past episode can be
completed weeks later, which is what actually happens when the certificate
arrives after the fact.

### 6.4 Browsing past episodes

The list screen's **Aktiv / Beendet / Alle** chips and search already are the
history view. Two additions:

- `_TreatmentTile`: when `hasSickLeave`, a `TagChip`-styled badge
  *"Krankenstand · 5 Tage"* (open leave: *"Krankenstand · Tag 3"*) next to the
  existing Aktiv/Beendet chip.
- Search (`_applyFilter`) also matches `doctor`.

### 6.5 Navigation

No new route, no new tab. Episodes live where treatments live: `/treatments`,
`/treatments/:id`, `/treatments/add`, `/treatments/:id/edit`.

The detail screen gains, between the dates block and the prescriptions, a
**Krankenstand** block using `DetailRow`: from–to (`formattedOr(l10n.ongoing)`),
the day count, the certificate number and the doctor — rendered only when
`hasSickLeave || doctor != null`, so existing treatments look unchanged. Each
prescription row gains its derived *"12 von 15 eingenommen"* subtitle (§5.2).

### 6.6 Dashboard

**No new Home card, no new section.** Home's goldens assert that the page does
not scroll at 964 dp (`home_golden_test.dart`), and Home is being edited by
another agent right now. Instead, the existing `_ActiveTreatmentsCard` tile shows
the same *"Krankenstand · Tag 3"* badge when the treatment has an open sick
leave. The golden fixture `goldenTreatments` has no sick leave, so
`home_light.png` / `home_dark.png` must stay **byte-identical** — the badge is
additive and invisible to the fixture. Whoever implements this re-runs the Home
goldens to *confirm* they are unchanged, and must not regenerate them.

## 7. Export: one episode, shared as text

Worth doing, and worth keeping tiny. The existing `/export` screen produces a
whole-cabinet PDF/CSV — the wrong shape for "send my employer the dates" and it
over-shares.

**Recommendation:** a **"Verlauf teilen"** entry in the treatment detail overflow
menu that builds a plain-text block and hands it to
`SharePlus.instance.share(ShareParams(text: …))` — no file, no new dependency,
pastes into WhatsApp, mail or a message to the doctor:

```
Stirnhöhlenentzündung
Krankheit: 02.03.2026 – 11.03.2026
Krankenstand: 03.03.2026 – 09.03.2026 (7 Tage)
Bescheinigungsnummer: 1234567890
Ärztin/Arzt: Dr. Rossi, Bolzano
Symptome: Kopfschmerzen, Fieber
Medikamente:
  Ibuprofen 400 — 1 Tablette, 3× täglich, 5 Tage — 14 von 15 eingenommen
  Tachipirina 1000 — 1 Tablette, bei Bedarf — 3 eingenommen
Notizen: …
```

Built from the treatment plus `prescriptionsByTreatmentProvider` and
`doseLogsByTreatmentProvider`, with every label from `l10n` (an `EpisodeLabels`
holder mirroring `ExportLabels.fromL10n`), dates through `DateTimeExtensions`.
It goes in `lib/services/export_service.dart` next to the other exporters, is
pure (returns a `String`, so it is unit-testable without a share sheet), and is
gated on `PlatformCapabilities.hasFileShare` only for the share step.

`exportTreatmentsCSV` gains four columns (sick-leave from/to, ref, doctor) — two
lines, keeps the bulk export honest. A per-episode PDF is deliberately not built
(§11, question 3).

## 8. Privacy

What changes: **nothing structural, and that is the point.**

- **On device.** The new columns live in the same local SQLite file as the rest;
  the app is local-only by default (`AppMode.localOnly`), and `BiometricGate`
  already guards the whole shell when the user enables it. No new store, no new
  file, no analytics.
- **Backup.** New columns ride the existing envelope automatically (§2.4). The
  envelope is plain JSON and is not encrypted today — that is an existing
  property, but a diagnosis plus a doctor's name raises the stakes, so the
  backup section of Settings should say what the file contains before it is
  shared. Worth one sentence in the existing copy, not a feature.
- **Cloud sync.** Unchanged and still opt-in: cloud mode is a deliberate
  setting, RLS scopes rows to `user_id`, and the columns sync exactly like
  `notes` (which can already hold anything). No new data class leaves the device
  that did not already.
- **Third-party data.** `doctor` and `sickLeaveRef` are another person's name and
  an official document number. Keep both optional, never put them in a
  notification body (reminder text uses medication + dosage only — nothing to
  change), and never include them in the bulk export by default beyond the CSV
  columns the user explicitly ticks.
- **Sharing.** The §7 share covers **one episode**, never the cabinet. That is
  the privacy-relevant design decision: the user hands an employer the dates, not
  their medicine list history.

## 9. Localisation

New keys (template `app_en.arb` first, then de/it), placed next to the existing
treatment block (~line 128 en / ~line 87 de). Plain placeholders, matching the
file's existing style (`"expiresInDays": "Läuft in {days} Tagen ab"`), not ICU
plurals.

| Key | en | de | it |
|---|---|---|---|
| `sickLeave` | Sick leave | Krankenstand | Malattia |
| `sickLeaveFrom` | Unable to work from | Arbeitsunfähig von | Assente dal |
| `sickLeaveTo` | Unable to work until | Arbeitsunfähig bis | Assente fino al |
| `sickLeaveDays` | {days} days off work | {days} Tage Krankenstand | {days} giorni di malattia |
| `sickLeaveDay` | Day {days} | Tag {days} | Giorno {days} |
| `sickLeaveRef` | Certificate no. | Bescheinigungsnummer | Numero di protocollo |
| `sickLeaveRefHint` | e.g. 1234567890 | z.B. 1234567890 | es. 1234567890 |
| `sickLeaveEndToday` | Also end sick leave today | Krankenstand ebenfalls heute beenden | Termina anche la malattia oggi |
| `sickLeaveToBeforeFrom` | The end date is before the start date | Das Enddatum liegt vor dem Startdatum | La data di fine precede quella di inizio |
| `doctorLabel` | Doctor | Ärztin/Arzt | Medico |
| `doctorHint` | e.g. Dr. Rossi, Bolzano | z.B. Dr. Rossi, Bozen | es. Dr. Rossi, Bolzano |
| `scheduleAsNeeded` | As needed | Bei Bedarf | Al bisogno |
| `logDoseNow` | Log dose | Dosis eintragen | Registra dose |
| `dosesTakenOfPlanned` | {taken} of {total} taken | {taken} von {total} eingenommen | {taken} di {total} assunte |
| `dosesTakenAsNeeded` | {taken} taken | {taken} eingenommen | {taken} assunte |
| `shareEpisode` | Share record | Verlauf teilen | Condividi resoconto |
| `illness` | Illness | Krankheit | Malattia |

Reused, not re-invented: `ongoing`, `notes`, `symptoms`, `medications`,
`startDate`, `endDate`, `active`, `ended`, `delete`, `cancel`, `edit`.

Register: nouns everywhere (matching *Behandlungen / Medikamente / Dosen*); the
one full sentence (`sickLeaveToBeforeFrom`) stays neutral, and the end-sick-leave
checkbox is an imperative-free label, so the *Sie*/*du* split in the file is not
disturbed. `sickLeave` in Italian is `Malattia` and `illness` is also
`Malattia` — acceptable, because they never appear in the same view; if that
ever changes, the sick-leave block becomes *Certificato di malattia*.

## 10. Testing

- **Unit.** `sickLeaveDaysAt` (inclusive, open leave counts to `now`, DST-safe,
  null when unset); `TreatmentModel` round-trip local↔domain↔JSON with the four
  fields (extend `test/data/models/tombstone_roundtrip_test.dart`'s pattern);
  `Prescription` with `scheduleType: 'as_needed'` yields no dose times and
  `dosesPerDay == 0` (`test/domain/entities/prescription_test.dart`); migration
  15 adds the four columns (`test/data/local/app_database_test.dart`, following
  "migration 14 adds the ean column"); the §7 text builder against a fixed
  treatment + prescriptions + doses.
- **Widget.** Add/edit form saves and reloads the sick-leave section; the End
  dialog offers the checkbox only for an open leave and writes `sickLeaveTo`;
  the list tile shows the badge; the detail block renders only when there is
  data; "Dosis eintragen" inserts one taken dose.
- **Goldens.** No new golden. Home goldens must come out **byte-identical** —
  run them, do not update them. (`test/goldens/` is being edited by another
  agent; this work must not touch it.)
- **Sweeps.** `l10n_sweep_test` and the gen-l10n drift check cover the new
  strings; `clock_sweep_test` covers the day counter.
- **Docs.** Update `docs/architecture.md`: `kSchemaVersion` **15** (it currently
  says 13, already stale) and one line on the sick-leave columns.

## 11. Deliberately out of scope

1. **A separate `SicknessEpisode` entity or table** — §3.
2. **Renaming `Treatment`** anywhere in code, SQL or the tab labels — churn
   without user gain, and it would collide with the Home work in flight.
3. **A photo of the sick note.** Tempting, but photos go into the backup
   envelope base64-encoded and the export already has a 150 MB photo problem
   (`largePhotoBytes`). The certificate number is what an employer asks for.
4. **An ICD-10 / diagnosis catalogue or a second `diagnosis` field** — the free
   name field is the right granularity for a household log; a catalogue is a
   data-source project of its own (cf. the AIFA register).
5. **Multiple sick-leave segments per episode** (an extension, a *Verlängerung*).
   v1 is one range; a relapse after returning to work is a second episode, which
   is also how an employer sees it. If it turns out to be needed, it becomes a
   child table and nothing designed here has to be undone.
6. **Symptom severity, daily temperature, a symptom diary** — a whole feature;
   `notes` plus `symptomTags` covers "how it went".
7. **Employer fields, HR workflows, calendar/leave integrations, reminders to
   send the certificate.**
8. **A new dashboard card** — §6.6.
9. **A per-episode PDF** — text first (§7, question 3).

## 12. Open questions for the user

1. **Does the tab stay "Behandlungen"?** An illness episode and a therapy are the
   same record here, so the Krankenstand fields appear *inside* a treatment
   rather than as a new tab.
   *Recommendation:* keep "Behandlungen / Treatments / Trattamenti" as-is. If
   "Behandlung" feels wrong for "I had sinusitis", the cheapest fix is rewording
   two or three l10n strings (e.g. the empty state and the form title) — not a
   new section.
2. **Ad-hoc medicines: add the "bei Bedarf" schedule type (§5.3)?** It is what
   makes "I took one ibuprofen when it hurt" recordable without inventing a plan,
   and it costs one schedule chip plus a "Dosis eintragen" button.
   *Recommendation:* yes — without it the episode's medication list will be
   quietly wrong for exactly the case the user described.
3. **Export as shared text, or as a one-page PDF?** The PDF machinery already
   exists (`pdf` package, `ExportService.exportPDF`), so a PDF is maybe 40 extra
   lines, but it produces a file to manage rather than something pasteable.
   *Recommendation:* start with the text share; add the PDF later only if an
   employer actually asks for a document.
