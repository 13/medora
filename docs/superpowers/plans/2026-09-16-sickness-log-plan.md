# Sickness log — illness episodes with sick leave (Krankenstand) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user record a complete illness episode — what it was, the days it lasted, the separate certified sick-leave period (Krankenstand) with its certificate number and doctor, every medicine taken during it (scheduled *and* ad hoc), and share that one episode as pasteable text — without adding a screen, a tab or an entity.

**Architecture:** A `Treatment` already *is* an illness episode (name, symptom tags, patient tags, start/end, active, notes), so this work extends it with four nullable columns (`sick_leave_from`, `sick_leave_to`, `sick_leave_ref`, `doctor`) rather than introducing a parallel `SicknessEpisode` — columns ride the existing backup envelope and sync path for free, a new table would need its own datasource pair, RLS, tombstone triggers, `SyncService` wiring and backup table lists. The medication list of an episode is **derived** from the dose history that already exists (`dose_logs` → `prescriptions.treatment_id`), never retyped, and a third `scheduleType` value `'as_needed'` makes "I took one ibuprofen when it hurt" recordable without inventing a schedule. Data layer lands first (Tasks 1–3), then the flows that write the fields (4–5), then the medication side (6) and the read-out (7).

**Tech Stack:** Flutter 3.44.6 / Dart SDK ^3.12.0 via `fvm` (never bare `dart`/`flutter`), flutter_riverpod 3.4, go_router 18, sqflite + `sqflite_common_ffi` in tests, Supabase (`supabase_flutter` 2.9) with SQL migrations under `supabase/migrations/`, ARB localisation in en/de/it via `flutter gen-l10n`, `share_plus` 13.3 (already a dependency), golden tests with committed PNGs under `test/goldens/`.

## Global Constraints

- `fvm dart format --set-exit-if-changed .` clean.
- `fvm flutter analyze --fatal-infos` clean.
- `fvm flutter test` green.
- `flutter gen-l10n` produces no diff and `untranslated.txt` is `{}`.
- Guard tests stay green: theme sweep (`test/presentation/theme_sweep_test.dart`, no hardcoded colors), l10n sweep (`test/presentation/l10n_sweep_test.dart`), clock sweep (`test/presentation/clock_sweep_test.dart`: no `DateTime.now()` in `lib/presentation` or `lib/domain` — take the time from `nowProvider`).
- Golden PNGs change only in a task that explicitly re-records them and says why, and the Home goldens (`test/goldens/home_light.png`, `test/goldens/home_dark.png`) must stay byte-identical.
- Local schema changes only via a new ordered migration, never by editing an applied one.
- Every user-visible string exists in en/de/it with natural German and Italian.
- No new pub dependencies unless a task names and justifies it.
- Commits end with the two lines `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS`.

---

## ⚠️ Read this before starting

**Briefs in earlier plans repeatedly contained snippets that did not match the code.** Every code block below was read out of the working tree on `dashboard-fixes` at v0.2.4+16. You must still verify before you edit: open the file, confirm the surrounding lines match what this plan quotes, and if they do not, **implement the intent against the real code and report the deviation in your task summary**. Do not silently adapt, and do not paste a block that no longer applies. Line numbers are accurate at v0.2.4+16 and drift as earlier tasks land — anchor on content, not on numbers.

**Another agent is editing `lib/presentation/screens/home/home_screen.dart`, `lib/presentation/widgets/shared_widgets.dart` and the Home goldens on this branch.** Task 4 touches `home_screen.dart` in one small place; rebase/re-read before editing it, and never run `--update-goldens`.

### Release note — apply the Supabase migration first

`TreatmentRemoteDatasource` uploads `TreatmentModel.toJson()` as a **whole row**. A client running local schema v15 therefore sends `sick_leave_from`, `sick_leave_to`, `sick_leave_ref` and `doctor` on every treatment push, and PostgREST rejects the whole row with `PGRST204` ("column not found") if the server does not have them yet.

**`supabase/migrations/20260917000000_treatment_sick_leave.sql` must be applied to the Supabase project before an updated client syncs**, exactly as with `20260916000000_medication_ean.sql` in the previous release. Local-only users (`AppMode.localOnly`, the default) are unaffected.

---

## Findings that change the scope

Checked against the working tree before planning. Four of these add work the design did not name; each is owned by the task that fixes it.

1. **`TreatmentModel` has no `copyWith`.** The design (§4.5) says to fix `endTreatment` by switching it to `existing.copyWith(...)`, but `existing` is a `TreatmentModel` (`localDatasource.getTreatmentById` returns the model), and only the *entity* `Treatment` has `copyWith`. **Task 3 adds `TreatmentModel.copyWith`** covering every field including `deletedAt`, then uses it.
2. **The landmine has a second half: the remote push is partial.** `TreatmentRepositoryImpl.endTreatment` calls `_syncInBackground((r) => r.endTreatment(id), id)`, and `TreatmentRemoteDatasource.endTreatment` sends **only** `is_active` and `end_date`. `_syncInBackground` then calls `localDatasource.markSynced(id)` on success — so the local row stops being pending and **any column that partial update omits never reaches the server at all**. Today that is harmless (nothing else changes at end-time); once `sick_leave_to` is written at end-time it is live data loss on every cloud user's "End". **Task 3 pushes the whole row with `upsertTreatment` and deletes the partial `endTreatment` remote method** (its only caller is the repository; `test/helpers/fake_remotes.dart:184-186` overrides it and loses that override).
3. **`AddTreatmentScreen` does not use the shared form widgets.** It renders its start/end dates as raw `InkWell` + `InputDecorator` with a hand-rolled `'$year-$month-$day'` string, and imports neither `FormSection` nor `DatePickerField`. The new Krankenstand section uses both (they are shared, tested and locale-aware); the two existing date fields are **left exactly as they are** — restyling them is a separate change that would move text in a screen nobody has a widget test for yet. Expect the new dates to render as `05.03.2026` (locale-aware) next to the old ones' `2026-03-05`. Task 4 notes this in its summary; do not "fix" it in passing.
4. **No treatment screen has a widget test.** `test/presentation/screens/prescription_sheet_test.dart` is the only test that touches `lib/presentation/screens/treatment/`, and it drives the sheet through a `_Host` stub. Tasks 4, 5 and 6 create the first widget tests for `AddTreatmentScreen`, `TreatmentDetailScreen` and `TreatmentListScreen`; budget for that, and reuse `pumpMedoraApp` + `setUpTestDatabase` + `seedPrescription` rather than inventing harnesses.

### Traps

- **`copyWith` cannot clear a field.** Every `copyWith` in this codebase is the `value ?? this.value` shape, so passing `null` keeps the old value. Clearing a sick-leave date in the edit form therefore goes through the `Treatment(...)` constructor (which `_saveTreatment` already uses), never through `copyWith`. Do not "improve" `copyWith` with sentinel objects — nothing else in the codebase does that.
- **Do not add the new columns to `AppDatabase.createBaseSchema`.** Its doc comment says *"The base (v10) schema. New columns go into [kMigrations], not here."* `onCreate` runs `createBaseSchema` and then **every** migration in order, so a fresh database gets the columns from migration 15. Adding them in both places makes `ALTER TABLE` throw "duplicate column name" on first launch.
- **`untranslated.txt` is at the repo root**, not under `lib/l10n/` (`l10n.yaml` sets `untranslated-messages-file: untranslated.txt`, resolved relative to the project root). It currently contains `{}`; after adding keys to all three ARBs it must still contain `{}`.
- **An as-needed prescription must never generate a dose.** `TodaysDoseLogsNotifier._ensureDoseLogsExistInBackground` and `DoseLogRepositoryImpl.generateDoseLogsForPrescription` both drive off `scheduledDoseTimes`, and `ReminderScheduler` only ever loads *pending* doses — returning `const []` from `scheduledDoseTimes` is what keeps all three quiet. Verify with a test, do not assume.

---

## File structure

**Domain (pure, no Flutter, no clock):**
- `lib/domain/entities/treatment.dart` — 4 nullable fields, `copyWith`, `hasSickLeave`, `isSickLeaveOpen`, `sickLeaveDaysAt(now)` (Task 1).
- `lib/domain/entities/prescription.dart` — `'as_needed'` branches in `dosesPerDay` and `scheduledDoseTimes` (Task 6).
- `lib/domain/repositories/treatment_repository.dart` — `endTreatment` gains `{bool endSickLeave}` (Task 5).
- `lib/domain/repositories/dose_log_repository.dart` — `getDoseLogsByTreatment` (Task 7).

**Data:**
- `lib/data/local/migrations.dart` — `Migration(15, …)`, `kSchemaVersion = 15` (Task 2).
- `lib/data/models/treatment_model.dart` — 4 fields through 5 mapping functions (Task 2) + `copyWith` (Task 3).
- `lib/data/datasources/treatment_local_datasource.dart` — `_fromRow` / `_toRow` (Task 2).
- `lib/data/datasources/treatment_remote_datasource.dart` — delete the partial `endTreatment` (Task 3).
- `lib/data/datasources/dose_log_local_datasource.dart` — `getDoseLogsByTreatment` (Task 7).
- `lib/data/repositories/treatment_repository_impl.dart` — the `endTreatment` rebuild → `copyWith` + whole-row push (Task 3), sick-leave close (Task 5).
- `lib/data/repositories/dose_log_repository_impl.dart` — `getDoseLogsByTreatment` (Task 7).
- `supabase/migrations/20260917000000_treatment_sick_leave.sql` — new (Task 2).

**Presentation:**
- `lib/presentation/screens/treatment/add_treatment_screen.dart` — Krankenstand `FormSection` (Task 4).
- `lib/presentation/screens/treatment/treatment_detail_screen.dart` — Krankenstand block (Task 4), end dialog (Task 5), as-needed summary + "Dosis eintragen" (Task 6), dose counts + share (Task 7).
- `lib/presentation/screens/treatment/treatment_list_screen.dart` — badge, doctor search (Task 4), end dialog (Task 5).
- `lib/presentation/screens/treatment/end_treatment_dialog.dart` — **new**, shared confirm-and-end used by both screens (Task 5).
- `lib/presentation/screens/treatment/prescription_sheet.dart` — third schedule segment (Task 6).
- `lib/presentation/screens/home/home_screen.dart` — badge on `_ActiveTreatmentTile` (Task 4).
- `lib/presentation/providers/dose_providers.dart` — `DoseActions.logAsNeededDose` (Task 6), `doseLogsByTreatmentProvider` (Task 7).
- `lib/presentation/providers/treatment_providers.dart` — `endTreatment({bool endSickLeave})` (Task 5).

**Services / docs / l10n:**
- `lib/services/export_service.dart` — `EpisodeLabels`, `buildEpisodeSummary`, 4 CSV columns (Task 7).
- `lib/l10n/app_{en,de,it}.arb` — Task 4 (10 keys), Task 5 (1), Task 6 (3), Task 7 (4).
- `docs/architecture.md` — schema version 13 → 15 plus one sentence (Task 2).

---

## Task 1: Sick-leave fields and derived getters on `Treatment`

Pure domain change. Nothing reads the fields yet; this task exists so the day arithmetic gets its own test cycle before any persistence or UI depends on it.

**Files:**
- Modify: `lib/domain/entities/treatment.dart`
- Test: `test/domain/entities/treatment_test.dart` (create)

**Interfaces:**
- Consumes: `calendarDaysBetween(DateTime from, DateTime to) → int` from `lib/core/clock.dart` (re-anchors both dates to UTC midnight, so a DST transition inside the range cannot shave a day).
- Produces, on `Treatment`:
  - `final DateTime? sickLeaveFrom;` — date only, first day unable to work
  - `final DateTime? sickLeaveTo;` — date only, last day; null while the leave is open
  - `final String? sickLeaveRef;` — certificate / protocol number
  - `final String? doctor;` — free text
  - `bool get hasSickLeave`
  - `bool get isSickLeaveOpen`
  - `int? sickLeaveDaysAt(DateTime now)`
  - `Treatment copyWith({…, DateTime? sickLeaveFrom, DateTime? sickLeaveTo, String? sickLeaveRef, String? doctor})`

- [ ] **Step 1: Write the failing test**

Create `test/domain/entities/treatment_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/treatment.dart';

Treatment _t({
  DateTime? sickLeaveFrom,
  DateTime? sickLeaveTo,
  String? sickLeaveRef,
  String? doctor,
}) => Treatment(
  id: 't1',
  name: 'Stirnhöhlenentzündung',
  startDate: DateTime(2026, 3, 2),
  sickLeaveFrom: sickLeaveFrom,
  sickLeaveTo: sickLeaveTo,
  sickLeaveRef: sickLeaveRef,
  doctor: doctor,
);

void main() {
  group('hasSickLeave / isSickLeaveOpen', () {
    test('no sick leave recorded', () {
      final t = _t();
      expect(t.hasSickLeave, isFalse);
      expect(t.isSickLeaveOpen, isFalse);
    });

    test('an open leave has a start and no end', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.hasSickLeave, isTrue);
      expect(t.isSickLeaveOpen, isTrue);
    });

    test('a closed leave has both', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
      );
      expect(t.hasSickLeave, isTrue);
      expect(t.isSickLeaveOpen, isFalse);
    });
  });

  group('sickLeaveDaysAt', () {
    test('is null when no leave is recorded', () {
      expect(_t().sickLeaveDaysAt(DateTime(2026, 3, 10)), isNull);
    });

    test('counts both end days: Mon to Fri is five days, not four', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 2), // Monday
        sickLeaveTo: DateTime(2026, 3, 6), // Friday
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), 5);
    });

    test('a single day counts as one', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 3),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), 1);
    });

    test('an open leave counts up to now', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5)), 3);
    });

    test('the time of day in now is ignored', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5, 23, 30)), 3);
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5, 0, 1)), 3);
    });

    test('a DST transition inside the range does not shave a day', () {
      // Europe/Rome moves to summer time on 2026-03-29.
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 28),
        sickLeaveTo: DateTime(2026, 3, 30),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 4, 2)), 3);
    });

    test('a closed leave ignores now entirely', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 4)), 7);
      expect(t.sickLeaveDaysAt(DateTime(2027, 1, 1)), 7);
    });
  });

  test('copyWith carries the sick-leave fields through', () {
    final t = _t(
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    );
    final ended = t.copyWith(
      isActive: false,
      sickLeaveTo: DateTime(2026, 3, 9),
    );
    expect(ended.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(ended.sickLeaveTo, DateTime(2026, 3, 9));
    expect(ended.sickLeaveRef, '1234567890');
    expect(ended.doctor, 'Dr. Rossi, Bozen');
    expect(ended.isActive, isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fvm flutter test test/domain/entities/treatment_test.dart`
Expected: FAIL to compile — `No named parameter with the name 'sickLeaveFrom'`.

- [ ] **Step 3: Add the fields and getters**

In `lib/domain/entities/treatment.dart`, add the import, the four constructor parameters (after `this.notes`), the four fields, the getters, and the four `copyWith` parameters:

```dart
import 'package:medora/core/clock.dart';
```

Constructor — insert after `this.notes,`:

```dart
    this.sickLeaveFrom,
    this.sickLeaveTo,
    this.sickLeaveRef,
    this.doctor,
```

Fields — insert after `final String? notes;`:

```dart
  /// First day unable to work (date only). Null when no sick leave was
  /// recorded: an ordinary therapy simply leaves these empty.
  final DateTime? sickLeaveFrom;

  /// Last day unable to work (date only); null while the leave is open.
  final DateTime? sickLeaveTo;

  /// Certificate / protocol number (IT: numero di protocollo).
  final String? sickLeaveRef;

  /// Free text, e.g. "Dr. Rossi, Bolzano".
  final String? doctor;
```

Getters — insert after the `durationDays` getter:

```dart
  bool get hasSickLeave => sickLeaveFrom != null;

  bool get isSickLeaveOpen => sickLeaveFrom != null && sickLeaveTo == null;

  /// Inclusive calendar days of sick leave; null when none is recorded.
  ///
  /// An open leave counts up to [now]. Inclusive (+1) because a sick note
  /// "from Monday to Friday" means five days, not four.
  int? sickLeaveDaysAt(DateTime now) => sickLeaveFrom == null
      ? null
      : calendarDaysBetween(sickLeaveFrom!, sickLeaveTo ?? now) + 1;
```

`copyWith` — add the four parameters to the signature (after `String? notes,`) and the four arguments to the returned `Treatment`:

```dart
    DateTime? sickLeaveFrom,
    DateTime? sickLeaveTo,
    String? sickLeaveRef,
    String? doctor,
```

```dart
      sickLeaveFrom: sickLeaveFrom ?? this.sickLeaveFrom,
      sickLeaveTo: sickLeaveTo ?? this.sickLeaveTo,
      sickLeaveRef: sickLeaveRef ?? this.sickLeaveRef,
      doctor: doctor ?? this.doctor,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/domain/entities/treatment_test.dart`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the guards**

Run: `fvm flutter test test/presentation/clock_sweep_test.dart && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed .`
Expected: all pass. (`calendarDaysBetween` is the seam; the entity never calls `DateTime.now()`.)

- [ ] **Step 6: Commit**

```bash
git add lib/domain/entities/treatment.dart test/domain/entities/treatment_test.dart
git commit -m "$(cat <<'EOF'
feat(treatment): sick-leave fields and inclusive day count on the entity

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 2: Migration 15, model and datasource mapping, Supabase migration

The four columns end to end through persistence: local schema, the model's five mapping functions, the local datasource's row mapping, the server-side DDL, and the architecture doc.

**Files:**
- Modify: `lib/data/local/migrations.dart` (`kSchemaVersion`, new `Migration(15, …)` at the end of `kMigrations`)
- Modify: `lib/data/models/treatment_model.dart`
- Modify: `lib/data/datasources/treatment_local_datasource.dart` (`_fromRow`, `_toRow`)
- Create: `supabase/migrations/20260917000000_treatment_sick_leave.sql`
- Modify: `docs/architecture.md:58-62`
- Test: `test/data/local/app_database_test.dart` (modify), `test/data/models/treatment_model_test.dart` (create), `test/data/datasources/treatment_local_datasource_test.dart` (create)

**Interfaces:**
- Consumes: `Treatment.sickLeaveFrom/sickLeaveTo/sickLeaveRef/doctor` (Task 1).
- Produces:
  - `const int kSchemaVersion = 15;`
  - `TreatmentModel({…, DateTime? sickLeaveFrom, DateTime? sickLeaveTo, String? sickLeaveRef, String? doctor})` with the four fields carried by `fromJson`, `fromLocalMap`, `toJson`, `toDomain` and `fromDomain`.
  - SQLite columns `treatments.sick_leave_from`, `sick_leave_to`, `sick_leave_ref`, `doctor` (all `TEXT`, nullable).
  - Postgres columns `public.treatments.sick_leave_from date`, `sick_leave_to date`, `sick_leave_ref text`, `doctor text`.
- Dates serialise exactly like `start_date`/`end_date`: `toIso8601String().split('T').first` on the way out, `DateTime.tryParse` on the way in.

**Existing tests that must change:** `test/data/local/app_database_test.dart` asserts `appliedMigrations()` equals `[11, 12, 13, 14]` in **four** places (the v10-upgrade test twice, the migration-12 test, the migration-13 test). All four become `[11, 12, 13, 14, 15]`. This is not a regression — the list is the ledger, and the ledger gains an entry.

- [ ] **Step 1: Write the failing tests**

Add to `test/data/local/app_database_test.dart`, next to the migration-14 test:

```dart
  test('migration 15 adds the sick-leave and doctor columns', () async {
    final db = await AppDatabase.instance.database;
    expect(
      await columnsOf(db, 'treatments'),
      containsAll(['sick_leave_from', 'sick_leave_to', 'sick_leave_ref', 'doctor']),
    );
  });

  test('upgrading a v14 database adds the sick-leave columns', () async {
    final dir = await Directory.systemTemp.createTemp('medora_mig15_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, _) async {
          await AppDatabase.createBaseSchema(db);
          for (final m in kMigrations.where((m) => m.version <= 14)) {
            await m.run(db);
          }
        },
      ),
    );
    await legacy.insert('treatments', {
      'id': 't-old',
      'name': 'Influenza',
      'start_date': '2026-03-01',
      'is_active': 1,
    });
    expect(
      await columnsOf(legacy, 'treatments'),
      isNot(contains('sick_leave_from')),
    );
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final upgraded = await AppDatabase.instance.database;

    expect(await columnsOf(upgraded, 'treatments'), contains('sick_leave_from'));
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12, 13, 14, 15]);
    // The pre-existing row survives with the new columns null.
    final row = (await upgraded.query(
      'treatments',
      where: 'id = ?',
      whereArgs: ['t-old'],
    )).single;
    expect(row['name'], 'Influenza');
    expect(row['sick_leave_from'], isNull);
    expect(row['doctor'], isNull);

    await AppDatabase.instance.reset();
    await dir.delete(recursive: true);
  });
```

Update the four existing `[11, 12, 13, 14]` expectations to `[11, 12, 13, 14, 15]`.

Create `test/data/models/treatment_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/treatment.dart';

void main() {
  final treatment = Treatment(
    id: 't1',
    name: 'Stirnhöhlenentzündung',
    startDate: DateTime(2026, 3, 2),
    endDate: DateTime(2026, 3, 11),
    sickLeaveFrom: DateTime(2026, 3, 3),
    sickLeaveTo: DateTime(2026, 3, 9),
    sickLeaveRef: '1234567890',
    doctor: 'Dr. Rossi, Bozen',
  );

  test('domain -> model -> domain preserves the sick-leave fields', () {
    final back = TreatmentModel.fromDomain(treatment).toDomain();
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });

  test('toJson writes date-only strings, like start_date', () {
    final json = TreatmentModel.fromDomain(treatment).toJson();
    expect(json['sick_leave_from'], '2026-03-03');
    expect(json['sick_leave_to'], '2026-03-09');
    expect(json['sick_leave_ref'], '1234567890');
    expect(json['doctor'], 'Dr. Rossi, Bozen');
  });

  test('json round-trip keeps the fields', () {
    final json = TreatmentModel.fromDomain(treatment).toJson();
    final back = TreatmentModel.fromJson(json);
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });

  test('a row from before v15 parses with the fields null', () {
    final legacy = TreatmentModel.fromJson({
      'id': 't1',
      'name': 'Influenza',
      'start_date': '2026-03-02',
      'is_active': true,
    });
    expect(legacy.sickLeaveFrom, isNull);
    expect(legacy.sickLeaveTo, isNull);
    expect(legacy.sickLeaveRef, isNull);
    expect(legacy.doctor, isNull);
  });

  test('local map round-trip keeps the fields', () {
    final model = TreatmentModel.fromDomain(treatment);
    final back = TreatmentModel.fromLocalMap({
      'id': model.id,
      'name': model.name,
      'start_date': '2026-03-02',
      'is_active': 1,
      'sick_leave_from': '2026-03-03',
      'sick_leave_to': '2026-03-09',
      'sick_leave_ref': '1234567890',
      'doctor': 'Dr. Rossi, Bozen',
    });
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });
}
```

Create `test/data/datasources/treatment_local_datasource_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('upsert then read keeps the sick-leave columns', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(
        id: 't1',
        name: 'Stirnhöhlenentzündung',
        startDate: DateTime(2026, 3, 2),
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
        sickLeaveRef: '1234567890',
        doctor: 'Dr. Rossi, Bozen',
      ),
      syncStatus: SyncStatus.pendingCreate,
    );

    final stored = await ds.getTreatmentById('t1');
    expect(stored!.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(stored.sickLeaveTo, DateTime(2026, 3, 9));
    expect(stored.sickLeaveRef, '1234567890');
    expect(stored.doctor, 'Dr. Rossi, Bozen');

    final db = await AppDatabase.instance.database;
    final row = (await db.query('treatments', where: 'id = ?', whereArgs: ['t1'])).single;
    expect(row['sick_leave_from'], '2026-03-03');
    expect(row['sick_leave_to'], '2026-03-09');
  });

  test('a treatment with no sick leave stores nulls', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(id: 't2', name: 'Vitamin D', startDate: DateTime(2026, 3, 2)),
      syncStatus: SyncStatus.pendingCreate,
    );
    final stored = await ds.getTreatmentById('t2');
    expect(stored!.sickLeaveFrom, isNull);
    expect(stored.sickLeaveTo, isNull);
    expect(stored.sickLeaveRef, isNull);
    expect(stored.doctor, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/data/local/app_database_test.dart test/data/models/treatment_model_test.dart test/data/datasources/treatment_local_datasource_test.dart`
Expected: FAIL — `No named parameter with the name 'sickLeaveFrom'` in the model tests, and `contains('sick_leave_from')` failing in the database test.

- [ ] **Step 3: Add migration 15**

In `lib/data/local/migrations.dart`, change `const int kSchemaVersion = 14;` to `15`, and append to `kMigrations` (after the v14 entry, before the closing `];`):

```dart
  // v15: sick leave (Krankenstand) on an illness episode: the days unable to
  // work, which need not equal the illness period, plus the certificate
  // number and the doctor. All nullable — an ordinary therapy leaves them
  // empty. No index: the list screen loads every treatment and filters in
  // Dart.
  Migration(15, (db) async {
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_from TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_to TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_ref TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN doctor TEXT');
  }),
```

Do **not** touch `AppDatabase.createBaseSchema`.

- [ ] **Step 4: Carry the fields through `TreatmentModel`**

In `lib/data/models/treatment_model.dart`: add to the constructor after `this.notes,`:

```dart
    this.sickLeaveFrom,
    this.sickLeaveTo,
    this.sickLeaveRef,
    this.doctor,
```

Add the fields after `final String? notes;`:

```dart
  final DateTime? sickLeaveFrom;
  final DateTime? sickLeaveTo;
  final String? sickLeaveRef;
  final String? doctor;
```

In `fromJson`, after the `notes:` line:

```dart
      sickLeaveFrom: json['sick_leave_from'] != null
          ? DateTime.tryParse(json['sick_leave_from'] as String)
          : null,
      sickLeaveTo: json['sick_leave_to'] != null
          ? DateTime.tryParse(json['sick_leave_to'] as String)
          : null,
      sickLeaveRef: json['sick_leave_ref'] as String?,
      doctor: json['doctor'] as String?,
```

In `fromLocalMap`, after the `notes:` line:

```dart
      sickLeaveFrom: map['sick_leave_from'] != null
          ? DateTime.tryParse(map['sick_leave_from'] as String)
          : null,
      sickLeaveTo: map['sick_leave_to'] != null
          ? DateTime.tryParse(map['sick_leave_to'] as String)
          : null,
      sickLeaveRef: map['sick_leave_ref'] as String?,
      doctor: map['doctor'] as String?,
```

In `toJson`, after `'notes': notes,`:

```dart
      'sick_leave_from': sickLeaveFrom?.toIso8601String().split('T').first,
      'sick_leave_to': sickLeaveTo?.toIso8601String().split('T').first,
      'sick_leave_ref': sickLeaveRef,
      'doctor': doctor,
```

In `toDomain`, after `notes: notes,`, and in `fromDomain`, after `notes: entity.notes,`:

```dart
      sickLeaveFrom: sickLeaveFrom,
      sickLeaveTo: sickLeaveTo,
      sickLeaveRef: sickLeaveRef,
      doctor: doctor,
```

```dart
      sickLeaveFrom: entity.sickLeaveFrom,
      sickLeaveTo: entity.sickLeaveTo,
      sickLeaveRef: entity.sickLeaveRef,
      doctor: entity.doctor,
```

- [ ] **Step 5: Carry the fields through the local datasource**

In `lib/data/datasources/treatment_local_datasource.dart`, `_fromRow` after `notes: row['notes'] as String?,`:

```dart
      sickLeaveFrom: row['sick_leave_from'] != null
          ? DateTime.tryParse(row['sick_leave_from'] as String)
          : null,
      sickLeaveTo: row['sick_leave_to'] != null
          ? DateTime.tryParse(row['sick_leave_to'] as String)
          : null,
      sickLeaveRef: row['sick_leave_ref'] as String?,
      doctor: row['doctor'] as String?,
```

and `_toRow` after `'notes': m.notes,`:

```dart
      'sick_leave_from': m.sickLeaveFrom?.toIso8601String().split('T').first,
      'sick_leave_to': m.sickLeaveTo?.toIso8601String().split('T').first,
      'sick_leave_ref': m.sickLeaveRef,
      'doctor': m.doctor,
```

- [ ] **Step 6: Add the Supabase migration**

Create `supabase/migrations/20260917000000_treatment_sick_leave.sql`:

```sql
-- Medora: sick leave (Krankenstand) on a treatment. The treatment remote
-- datasource uploads `TreatmentModel.toJson()` as a whole row, so these
-- columns must exist before a client on schema v15 syncs.
--
-- No RLS change: the treatments_* policies are already `user_id = auth.uid()`
-- and a column is not a row. No trigger change: the tombstone cascade fires
-- per row, not per column.
alter table if exists public.treatments
  add column if not exists sick_leave_from date,
  add column if not exists sick_leave_to   date,
  add column if not exists sick_leave_ref  text,
  add column if not exists doctor          text;
```

- [ ] **Step 7: Update the architecture doc**

In `docs/architecture.md`, replace lines 58-62 (the sentence that still says **13**) with:

```markdown
`lib/data/local/migrations.dart` is an append-only ledger of `Migration`
(version + function); `kSchemaVersion` is **15** and must equal the last entry,
and existing migrations are never edited: v11 added tombstone columns, v12 bare
photo filenames, v13 naive-local dose timestamps so string ranges line up with
local day boundaries, v14 the medication EAN, v15 the sick-leave columns
(`sick_leave_from`, `sick_leave_to`, `sick_leave_ref`, `doctor`) on
`treatments`, all nullable. `BackupService` writes the database and photo folder into one versioned JSON
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `fvm flutter test test/data/ && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed .`
Expected: PASS. If `migration 15 adds …` passes but the v14-upgrade test fails with "duplicate column name: sick_leave_from", the columns were also added to `createBaseSchema` — remove them from there.

- [ ] **Step 9: Commit**

```bash
git add lib/data/local/migrations.dart lib/data/models/treatment_model.dart \
  lib/data/datasources/treatment_local_datasource.dart \
  supabase/migrations/20260917000000_treatment_sick_leave.sql docs/architecture.md \
  test/data/local/app_database_test.dart test/data/models/treatment_model_test.dart \
  test/data/datasources/treatment_local_datasource_test.dart
git commit -m "$(cat <<'EOF'
feat(data): migration 15 adds the sick-leave columns to treatments

Local schema v15 plus the matching Supabase DDL. The remote datasource
uploads the whole row, so 20260917000000_treatment_sick_leave.sql must be
applied before a v15 client syncs.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 3: Backup, sync and end-treatment coherence for the new columns

**This is the task that defuses the landmine.** `TreatmentRepositoryImpl.endTreatment` rebuilds `TreatmentModel` field by field instead of copying, so it drops every field it does not name — the four new ones included. And `_syncInBackground` pushes a *partial* remote update and then marks the row synced, so whatever the partial update omits never reaches the server. Both halves are fixed here, and the three persistence paths (backup round-trip, sync push, sync pull) get tests that would have caught either.

**Files:**
- Modify: `lib/data/models/treatment_model.dart` (add `copyWith`)
- Modify: `lib/data/repositories/treatment_repository_impl.dart:104-127` (`endTreatment`)
- Modify: `lib/data/datasources/treatment_remote_datasource.dart` (delete the partial `endTreatment`)
- Modify: `test/helpers/fake_remotes.dart:184-186` (drop the matching override)
- Test: `test/data/repositories/treatment_repository_test.dart` (create), `test/services/backup_service_test.dart` (add), `test/services/sync_service_test.dart` (add)

**Interfaces:**
- Consumes: `TreatmentModel` with the four fields (Task 2); `nextUpdatedAt(DateTime? previous, DateTime now)` from `lib/core/clock.dart`.
- Produces:
  - `TreatmentModel copyWith({String? id, String? userId, String? name, List<String>? patientTags, List<String>? symptomTags, DateTime? startDate, DateTime? endDate, bool? isActive, String? notes, DateTime? sickLeaveFrom, DateTime? sickLeaveTo, String? sickLeaveRef, String? doctor, DateTime? createdAt, DateTime? updatedAt, DateTime? deletedAt})`
  - `TreatmentRepositoryImpl.endTreatment` now pushes the **whole** row via `TreatmentRemoteDatasource.upsertTreatment(TreatmentModel)`.
  - `TreatmentRemoteDatasource.endTreatment(String id)` **no longer exists**.

**Existing tests that must change:** `test/helpers/fake_remotes.dart` — `FakeTreatmentRemote` loses its `endTreatment` override, because the method it overrides is gone. Nothing else references it (`grep -rn "endTreatment" lib/ test/` before and after).

- [ ] **Step 1: Write the failing test**

Create `test/data/repositories/treatment_repository_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  late TreatmentLocalDatasource local;
  late TreatmentRepositoryImpl repo;

  setUp(() {
    local = TreatmentLocalDatasource();
    repo = TreatmentRepositoryImpl(
      localDatasource: local,
      remoteDatasource: null, // local-only: no background push
    );
  });

  Future<void> seedEpisode() => local.upsert(
    TreatmentModel(
      id: 't1',
      name: 'Stirnhöhlenentzündung',
      patientTags: const ['Ben'],
      symptomTags: const ['Kopfschmerzen'],
      startDate: DateTime(2026, 3, 2),
      notes: 'ging langsam weg',
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    ),
    syncStatus: SyncStatus.synced,
  );

  test('endTreatment keeps every field it does not change', () async {
    await seedEpisode();

    final result = await repo.endTreatment('t1');
    expect(result.isSuccess, isTrue);

    final stored = (await local.getTreatmentById('t1'))!;
    expect(stored.isActive, isFalse);
    expect(stored.endDate, isNotNull);
    // The fields endTreatment must not silently drop:
    expect(stored.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(stored.sickLeaveRef, '1234567890');
    expect(stored.doctor, 'Dr. Rossi, Bozen');
    expect(stored.notes, 'ging langsam weg');
    expect(stored.patientTags, ['Ben']);
    expect(stored.symptomTags, ['Kopfschmerzen']);
  });

  test('endTreatment leaves the row pending so the whole row is pushed', () async {
    await seedEpisode();
    await repo.endTreatment('t1');

    final db = await AppDatabase.instance.database;
    final row = (await db.query('treatments', where: 'id = ?', whereArgs: ['t1'])).single;
    expect(row['sync_status'], SyncStatus.pendingUpdate);
  });

  test('endTreatment on a missing id fails instead of writing', () async {
    final result = await repo.endTreatment('nope');
    expect(result.isFailure, isTrue);
  });
}
```

Add to `test/services/backup_service_test.dart` (inside `main`, after the existing export/restore tests — reuse the file's `snapshot` and `makeService` helpers):

```dart
  test('the sick-leave columns survive an export/restore round trip', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('treatments', {
      'id': 't-sick',
      'name': 'Stirnhöhlenentzündung',
      'start_date': '2026-03-02',
      'end_date': '2026-03-11',
      'is_active': 0,
      'sick_leave_from': '2026-03-03',
      'sick_leave_to': '2026-03-09',
      'sick_leave_ref': '1234567890',
      'doctor': 'Dr. Rossi, Bozen',
      'created_at': '2026-03-02T08:00:00.000',
      'updated_at': '2026-03-11T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });
    final before = await snapshot(db);

    final file = await makeService().exportToFile(outDir);
    await AppDatabase.instance.clearAllData();
    await makeService().restore(file, mode: RestoreMode.replace);

    expect(await snapshot(db), before);
    final row = (await db.query('treatments', where: 'id = ?', whereArgs: ['t-sick'])).single;
    expect(row['sick_leave_from'], '2026-03-03');
    expect(row['sick_leave_to'], '2026-03-09');
    expect(row['sick_leave_ref'], '1234567890');
    expect(row['doctor'], 'Dr. Rossi, Bozen');
  });
```

> Check `restore`'s real signature in `lib/services/backup_service.dart` and the `RestoreMode` import before writing this — copy the call shape from the neighbouring restore tests in the same file rather than trusting the line above.

Add to `test/services/sync_service_test.dart` (inside `main`, using the file's existing `Harness`):

```dart
  test('a pending treatment pushes its sick-leave columns to the server', () async {
    final h = Harness();
    await TreatmentLocalDatasource().upsert(
      TreatmentModel(
        id: 't1',
        name: 'Stirnhöhlenentzündung',
        startDate: DateTime(2026, 3, 2),
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
        sickLeaveRef: '1234567890',
        doctor: 'Dr. Rossi, Bozen',
      ),
      syncStatus: SyncStatus.pendingCreate,
    );

    await h.service.syncAll();

    final remote = h.treatments.table.rows['t1']!;
    expect(remote['sick_leave_from'], '2026-03-03');
    expect(remote['sick_leave_to'], '2026-03-09');
    expect(remote['sick_leave_ref'], '1234567890');
    expect(remote['doctor'], 'Dr. Rossi, Bozen');
  });

  test('a pulled treatment stores its sick-leave columns locally', () async {
    final h = Harness();
    h.treatments.table.upsert({
      'id': 't2',
      'name': 'Grippe',
      'start_date': '2026-02-01',
      'is_active': true,
      'sick_leave_from': '2026-02-02',
      'sick_leave_to': '2026-02-05',
      'sick_leave_ref': 'AB-42',
      'doctor': 'Dr. Bianchi',
    });

    await h.service.syncAll();

    final stored = (await TreatmentLocalDatasource().getTreatmentById('t2'))!;
    expect(stored.sickLeaveFrom, DateTime(2026, 2, 2));
    expect(stored.sickLeaveTo, DateTime(2026, 2, 5));
    expect(stored.sickLeaveRef, 'AB-42');
    expect(stored.doctor, 'Dr. Bianchi');
  });
```

> Match `Harness`'s real construction and the `syncAll` call shape to the neighbouring tests in that file (some use `fakeAsync`); the assertions above are the point, the plumbing is the file's own.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/data/repositories/treatment_repository_test.dart`
Expected: FAIL — `endTreatment keeps every field it does not change` fails with `Expected: DateTime:<2026-03-03 00:00:00.000> Actual: <null>` for `sickLeaveFrom`. **That failure is the landmine; confirm you see it before fixing anything.**

- [ ] **Step 3: Add `TreatmentModel.copyWith`**

At the end of `lib/data/models/treatment_model.dart`, before the closing brace:

```dart
  /// Field-preserving copy. Use this instead of rebuilding the model by
  /// hand: a hand-rolled rebuild silently drops every field the author
  /// forgot, which is how the sick-leave columns were lost on "End".
  ///
  /// Note the codebase-wide `??` convention: passing null keeps the current
  /// value, it does not clear the field. Clear a field by constructing a
  /// new [TreatmentModel].
  TreatmentModel copyWith({
    String? id,
    String? userId,
    String? name,
    List<String>? patientTags,
    List<String>? symptomTags,
    DateTime? startDate,
    DateTime? endDate,
    bool? isActive,
    String? notes,
    DateTime? sickLeaveFrom,
    DateTime? sickLeaveTo,
    String? sickLeaveRef,
    String? doctor,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return TreatmentModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      patientTags: patientTags ?? this.patientTags,
      symptomTags: symptomTags ?? this.symptomTags,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isActive: isActive ?? this.isActive,
      notes: notes ?? this.notes,
      sickLeaveFrom: sickLeaveFrom ?? this.sickLeaveFrom,
      sickLeaveTo: sickLeaveTo ?? this.sickLeaveTo,
      sickLeaveRef: sickLeaveRef ?? this.sickLeaveRef,
      doctor: doctor ?? this.doctor,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
```

- [ ] **Step 4: Rewrite `endTreatment` to copy, and push the whole row**

Replace the body of `endTreatment` in `lib/data/repositories/treatment_repository_impl.dart`:

```dart
  @override
  Future<Result<Treatment>> endTreatment(String id) async {
    try {
      final existing = await localDatasource.getTreatmentById(id);
      if (existing == null) return const Result.failure('Treatment not found');
      final now = DateTime.now();
      // Copy, never rebuild: a field-by-field rebuild drops every column
      // the author did not list (this is how the sick-leave columns were
      // silently lost on every "End").
      final ended = existing.copyWith(
        endDate: now,
        isActive: false,
        updatedAt: nextUpdatedAt(existing.updatedAt, now),
      );
      await localDatasource.upsert(ended, syncStatus: SyncStatus.pendingUpdate);
      // Push the WHOLE row. A partial remote update followed by markSynced
      // would strand every column the update omitted.
      _syncInBackground((r) => r.upsertTreatment(ended), id);
      return Result.success(ended.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to end treatment: $e', st);
    }
  }
```

- [ ] **Step 5: Delete the partial remote `endTreatment`**

Remove this method from `lib/data/datasources/treatment_remote_datasource.dart`:

```dart
  Future<void> endTreatment(String id) async {
    await _client
        .from(AppConstants.treatmentsTable)
        .update({
          'is_active': false,
          'end_date': DateTime.now().toIso8601String().split('T').first,
        })
        .eq('id', id);
  }
```

and the matching override from `test/helpers/fake_remotes.dart`:

```dart
  @override
  Future<void> endTreatment(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': false});
```

Confirm nothing else calls it: `grep -rn "endTreatment" lib/ test/` should now only show the repository/provider/UI `endTreatment` (the domain-level one) and the l10n keys.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `fvm flutter test test/data/repositories/treatment_repository_test.dart test/services/backup_service_test.dart test/services/sync_service_test.dart`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `fvm flutter test && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed .`
Expected: green, goldens unchanged (`git status` shows no PNG modified).

- [ ] **Step 8: Commit**

```bash
git add lib/data/models/treatment_model.dart lib/data/repositories/treatment_repository_impl.dart \
  lib/data/datasources/treatment_remote_datasource.dart test/helpers/fake_remotes.dart \
  test/data/repositories/treatment_repository_test.dart test/services/backup_service_test.dart \
  test/services/sync_service_test.dart
git commit -m "$(cat <<'EOF'
fix(treatment): stop endTreatment dropping fields it does not name

endTreatment rebuilt TreatmentModel field by field, so it silently dropped
every column it forgot, and its background sync pushed a partial remote
update before marking the row synced - stranding those columns server-side
for good. Copy the model and push the whole row instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 4: The Krankenstand section, detail block and list badge

Everything that shows and captures the four fields, in one task because they share the ten localised strings.

**Files:**
- Modify: `lib/presentation/screens/treatment/add_treatment_screen.dart`
- Modify: `lib/presentation/screens/treatment/treatment_detail_screen.dart`
- Modify: `lib/presentation/screens/treatment/treatment_list_screen.dart`
- Modify: `lib/presentation/screens/home/home_screen.dart` (`_ActiveTreatmentsCard` / `_ActiveTreatmentTile`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_de.arb`, `lib/l10n/app_it.arb`
- Test: `test/presentation/screens/add_treatment_screen_test.dart` (create), `test/presentation/screens/treatment_detail_screen_test.dart` (create), `test/presentation/screens/treatment_list_screen_test.dart` (create)

**Interfaces:**
- Consumes: `Treatment.hasSickLeave`, `isSickLeaveOpen`, `sickLeaveDaysAt(now)` (Task 1); `FormSection({required String title, required IconData icon, required List<Widget> children, bool initiallyExpanded, String? summary, ValueNotifier<bool>? controller})`; `DatePickerField({required String label, required IconData icon, required DateTime? date, required DateTime now, required ValueChanged<DateTime?> onDateSelected, DateTime? firstDate, DateTime? lastDate})`; `DetailRow({required IconData icon, required String label, required String value})`; `TagChip({required String label, IconData? icon, double fontSize})`; `nowProvider`.
- Produces: the widget keys `Key('sickLeaveSection')`, `Key('sickLeaveFromField')`, `Key('sickLeaveToField')`, `Key('sickLeaveRefField')`, `Key('doctorField')` and `Key('sickLeaveBadge')`, and the l10n getters listed below. Later tasks reuse `l10n.sickLeave` and `l10n.sickLeaveDays`.

**Deviation from the design's l10n table, and why:** the design gives `sickLeaveDays` as *"{days} Tage Krankenstand"* but renders the badge as *"Krankenstand · 5 Tage"* — using both would read "Krankenstand · 5 Tage Krankenstand". `sickLeaveDays` is therefore the bare duration (`"{days} Tage"`), and every caller composes it with `l10n.sickLeave`. This produces exactly the strings the design shows, in the badge, the detail block and the share text.

- [ ] **Step 1: Add the ten l10n keys**

`lib/l10n/app_en.arb` — insert after `"ongoing": "Ongoing",`:

```json
  "sickLeave": "Sick leave",
  "sickLeaveFrom": "Unable to work from",
  "sickLeaveTo": "Unable to work until",
  "sickLeaveDays": "{days} days",
  "@sickLeaveDays": {
    "placeholders": {
      "days": { "type": "int" }
    }
  },
  "sickLeaveDay": "Day {days}",
  "@sickLeaveDay": {
    "placeholders": {
      "days": { "type": "int" }
    }
  },
  "sickLeaveRef": "Certificate no.",
  "sickLeaveRefHint": "e.g. 1234567890",
  "sickLeaveToBeforeFrom": "The end date is before the start date",
  "doctorLabel": "Doctor",
  "doctorHint": "e.g. Dr. Rossi, Bolzano",
```

`lib/l10n/app_de.arb` — insert after `"ongoing": "Laufend",`:

```json
  "sickLeave": "Krankenstand",
  "sickLeaveFrom": "Arbeitsunfähig von",
  "sickLeaveTo": "Arbeitsunfähig bis",
  "sickLeaveDays": "{days} Tage",
  "sickLeaveDay": "Tag {days}",
  "sickLeaveRef": "Bescheinigungsnummer",
  "sickLeaveRefHint": "z.B. 1234567890",
  "sickLeaveToBeforeFrom": "Das Enddatum liegt vor dem Startdatum",
  "doctorLabel": "Ärztin/Arzt",
  "doctorHint": "z.B. Dr. Rossi, Bozen",
```

`lib/l10n/app_it.arb` — insert after `"ongoing": "In corso",`:

```json
  "sickLeave": "Malattia",
  "sickLeaveFrom": "Assente dal",
  "sickLeaveTo": "Assente fino al",
  "sickLeaveDays": "{days} giorni",
  "sickLeaveDay": "Giorno {days}",
  "sickLeaveRef": "Numero di protocollo",
  "sickLeaveRefHint": "es. 1234567890",
  "sickLeaveToBeforeFrom": "La data di fine precede quella di inizio",
  "doctorLabel": "Medico",
  "doctorHint": "es. Dr. Rossi, Bolzano",
```

Run `fvm flutter gen-l10n` and check `untranslated.txt` is still `{}`.

- [ ] **Step 2: Write the failing tests**

Create `test/presentation/screens/add_treatment_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 12);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<void> pump(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    await pumpMedoraApp(
      tester,
      const AddTreatmentScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        nowProvider.overrideWithValue(() => now),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Krankenstand section is collapsed by default', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('sickLeaveSection')), findsOneWidget);
    // Collapsed: FormSection keeps the body in the tree (maintainState) but
    // hides it, so assert on visibility, not on presence.
    expect(
      tester.widget<Visibility>(
        find.descendant(
          of: find.byKey(const Key('sickLeaveSection')),
          matching: find.byType(Visibility),
        ),
      ).visible,
      isFalse,
    );
  });

  testWidgets('saving a sick leave writes all four columns', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextFormField).first, 'Stirnhöhlenentzündung');
    await tester.tap(find.byKey(const Key('sickLeaveSection')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sickLeaveFromField')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('sickLeaveRefField')), '1234567890');
    await tester.enterText(find.byKey(const Key('doctorField')), 'Dr. Rossi, Bozen');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create Treatment'));
    await tester.pumpAndSettle();

    final stored = (await TreatmentLocalDatasource().getTreatments()).single;
    expect(stored.name, 'Stirnhöhlenentzündung');
    expect(stored.sickLeaveFrom, isNotNull);
    expect(stored.sickLeaveRef, '1234567890');
    expect(stored.doctor, 'Dr. Rossi, Bozen');
  });

  testWidgets('an end date without a start date is rejected', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Grippe');
    await tester.tap(find.byKey(const Key('sickLeaveSection')));
    await tester.pumpAndSettle();

    // Pick only "unable to work until" and leave the start date empty.
    // (The "to before from" case is blocked one layer earlier by the
    // picker's firstDate; this drives the guard behind it, and it is the
    // case a user actually reaches.)
    await tester.tap(find.byKey(const Key('sickLeaveToField')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create Treatment'));
    await tester.pumpAndSettle();

    // The section is forced open, the error shows, nothing was written.
    expect(find.text('The end date is before the start date'), findsOneWidget);
    expect(await TreatmentLocalDatasource().getTreatments(), isEmpty);
  });
}
```

Create `test/presentation/screens/treatment_detail_screen_test.dart` and `test/presentation/screens/treatment_list_screen_test.dart` following the same shape: seed a treatment through `TreatmentLocalDatasource`, pump the screen with `nowProvider` pinned to `DateTime(2026, 3, 5, 12)`, and assert:

- detail: a treatment with `sickLeaveFrom: 2026-03-03`, `sickLeaveTo: 2026-03-09`, `sickLeaveRef: '1234567890'`, `doctor: 'Dr. Rossi, Bozen'` renders `find.text('Sick leave')`, `find.text('1234567890')`, `find.text('Dr. Rossi, Bozen')` and `find.text('7 days')`;
- detail: a treatment with no sick leave and no doctor renders **no** `Key('sickLeaveBlock')`;
- list: an open leave from `2026-03-03` at `now = 2026-03-05` renders a `Key('sickLeaveBadge')` whose text is `Sick leave · Day 3`;
- list: a closed leave `2026-03-03`→`2026-03-09` renders `Sick leave · 7 days`;
- list: a treatment with no sick leave renders no `Key('sickLeaveBadge')`;
- list: typing `Rossi` into the search field keeps a treatment whose only match is `doctor`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `fvm flutter test test/presentation/screens/add_treatment_screen_test.dart test/presentation/screens/treatment_detail_screen_test.dart test/presentation/screens/treatment_list_screen_test.dart`
Expected: FAIL — `Key('sickLeaveSection')` / `Key('sickLeaveBadge')` not found.

- [ ] **Step 4: Add the Krankenstand section to the form**

In `lib/presentation/screens/treatment/add_treatment_screen.dart`, add the imports:

```dart
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
```

Add state next to the existing fields:

```dart
  DateTime? _sickLeaveFrom;
  DateTime? _sickLeaveTo;
  late final TextEditingController _sickLeaveRefController;
  late final TextEditingController _doctorController;

  /// Two-way synced with the section's [FormSection.controller]: opens the
  /// section when an edited treatment already has sick-leave data, and
  /// force-opens it to reveal a validation error.
  final _sickLeaveExpanded = ValueNotifier<bool>(false);
  String? _sickLeaveError;
```

In `initState`, create the two controllers; in `dispose`, dispose them and `_sickLeaveExpanded`.

In `_loadExistingTreatment`'s `setState`, add:

```dart
          _sickLeaveFrom = t.sickLeaveFrom;
          _sickLeaveTo = t.sickLeaveTo;
          _sickLeaveRefController.text = t.sickLeaveRef ?? '';
          _doctorController.text = t.doctor ?? '';
          _sickLeaveExpanded.value = t.hasSickLeave || t.doctor != null;
```

In `build`, take the clock once at the top:

```dart
    final now = ref.watch(nowProvider)();
```

Insert the section into the `ListView` between the Notes field and the `SizedBox(height: 32)` that precedes the save button:

```dart
            const SizedBox(height: 16),

            // Sick leave (Krankenstand) — collapsed by default, so an
            // ordinary therapy still shows the form it always had.
            FormSection(
              key: const Key('sickLeaveSection'),
              title: l10n.sickLeave,
              icon: Icons.work_off,
              initiallyExpanded: false,
              controller: _sickLeaveExpanded,
              summary: _sickLeaveSummary(l10n),
              children: [
                DatePickerField(
                  key: const Key('sickLeaveFromField'),
                  label: l10n.sickLeaveFrom,
                  icon: Icons.event_busy,
                  date: _sickLeaveFrom,
                  now: now,
                  onDateSelected: (d) => setState(() {
                    _sickLeaveFrom = d;
                    _sickLeaveError = null;
                  }),
                ),
                const SizedBox(height: 12),
                DatePickerField(
                  key: const Key('sickLeaveToField'),
                  label: l10n.sickLeaveTo,
                  icon: Icons.event_available,
                  date: _sickLeaveTo,
                  now: now,
                  firstDate: _sickLeaveFrom,
                  onDateSelected: (d) => setState(() {
                    _sickLeaveTo = d;
                    _sickLeaveError = null;
                  }),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('sickLeaveRefField'),
                  controller: _sickLeaveRefController,
                  decoration: InputDecoration(
                    labelText: l10n.sickLeaveRef,
                    prefixIcon: const Icon(Icons.confirmation_number),
                    hintText: l10n.sickLeaveRefHint,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('doctorField'),
                  controller: _doctorController,
                  decoration: InputDecoration(
                    labelText: l10n.doctorLabel,
                    prefixIcon: const Icon(Icons.medical_services),
                    hintText: l10n.doctorHint,
                  ),
                ),
                if (_sickLeaveError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _sickLeaveError!,
                    style: TextStyle(
                      color: context.colors.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
```

Add the summary helper and the validator to the state class:

```dart
  /// The collapsed section's one-line summary: the range once a start date
  /// is set, otherwise nothing (FormSection hides a null summary).
  String? _sickLeaveSummary(AppLocalizations l10n) {
    if (_sickLeaveFrom == null) return null;
    return '${_sickLeaveFrom!.formatted} – ${_sickLeaveTo.formattedOr(l10n.ongoing)}';
  }

  /// Returns the error to show, or null when the section is consistent.
  /// An end without a start, or an end before its start, are both rejected.
  String? _validateSickLeave(AppLocalizations l10n) {
    if (_sickLeaveTo == null) return null;
    if (_sickLeaveFrom == null) return l10n.sickLeaveToBeforeFrom;
    return _sickLeaveTo!.isBefore(_sickLeaveFrom!)
        ? l10n.sickLeaveToBeforeFrom
        : null;
  }
```

`_sickLeaveSummary` needs `import 'package:medora/core/extensions.dart';` for `.formatted` / `.formattedOr`.

In `_saveTreatment`, before `setState(() => _isLoading = true);`:

```dart
    final sickLeaveError = _validateSickLeave(AppLocalizations.of(context));
    if (sickLeaveError != null) {
      setState(() => _sickLeaveError = sickLeaveError);
      _sickLeaveExpanded.value = true;
      return;
    }
```

and add the four fields to the `Treatment(...)` constructor call:

```dart
      sickLeaveFrom: _sickLeaveFrom,
      sickLeaveTo: _sickLeaveTo,
      sickLeaveRef: _sickLeaveRefController.text.trim().isEmpty
          ? null
          : _sickLeaveRefController.text.trim(),
      doctor: _doctorController.text.trim().isEmpty
          ? null
          : _doctorController.text.trim(),
```

> The constructor is the clearing path: `copyWith` cannot null a field, so a user who clears a date in the form must go through here — which `_saveTreatment` already does.

- [ ] **Step 5: Add the detail block**

In `lib/presentation/screens/treatment/treatment_detail_screen.dart`, take the clock in `build` (`final now = ref.watch(nowProvider)();`, importing `now_provider.dart`) and insert between the status `Card` and the `SizedBox(height: 20)` that precedes the prescriptions header:

```dart
              if (treatment.hasSickLeave || treatment.doctor != null) ...[
                const SizedBox(height: 12),
                Card(
                  key: const Key('sickLeaveBlock'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.work_off, color: context.colors.primary),
                            const SizedBox(width: 8),
                            Text(
                              l10n.sickLeave,
                              style: context.text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (treatment.sickLeaveFrom != null) ...[
                          DetailRow(
                            icon: Icons.event_busy,
                            label: l10n.sickLeaveFrom,
                            value: treatment.sickLeaveFrom!.formatted,
                          ),
                          DetailRow(
                            icon: Icons.event_available,
                            label: l10n.sickLeaveTo,
                            value: treatment.sickLeaveTo.formattedOr(l10n.ongoing),
                          ),
                          DetailRow(
                            icon: Icons.today,
                            label: l10n.durationDaysLabel,
                            value: l10n.sickLeaveDays(
                              treatment.sickLeaveDaysAt(now)!,
                            ),
                          ),
                        ],
                        if (treatment.sickLeaveRef != null)
                          DetailRow(
                            icon: Icons.confirmation_number,
                            label: l10n.sickLeaveRef,
                            value: treatment.sickLeaveRef!,
                          ),
                        if (treatment.doctor != null)
                          DetailRow(
                            icon: Icons.medical_services,
                            label: l10n.doctorLabel,
                            value: treatment.doctor!,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
```

- [ ] **Step 6: Add the list badge and the doctor search**

In `lib/presentation/screens/treatment/treatment_list_screen.dart`, extend `_applyFilter`'s search predicate with one clause:

```dart
            (t.notes ?? '').toLowerCase().contains(query) ||
            (t.doctor ?? '').toLowerCase().contains(query);
```

In `_TreatmentTile.build` (already a `ConsumerWidget`, so `ref` is in scope), read the clock and add the badge next to the Aktiv/Beendet chip — inside the `Row` that holds the status container and `startedOn`, after `const SizedBox(width: 8),`:

```dart
    final now = ref.watch(nowProvider)();
```

```dart
                if (treatment.hasSickLeave) ...[
                  TagChip(
                    key: const Key('sickLeaveBadge'),
                    label: treatment.isSickLeaveOpen
                        ? '${l10n.sickLeave} · ${l10n.sickLeaveDay(treatment.sickLeaveDaysAt(now)!)}'
                        : '${l10n.sickLeave} · ${l10n.sickLeaveDays(treatment.sickLeaveDaysAt(now)!)}',
                    icon: Icons.work_off,
                  ),
                  const SizedBox(width: 8),
                ],
```

Import `now_provider.dart`. If the row overflows at 360 dp, wrap its children in a `Wrap(spacing: 8, runSpacing: 4, …)` rather than shrinking the text.

- [ ] **Step 7: Add the badge to the Home tile**

In `lib/presentation/screens/home/home_screen.dart`, `_ActiveTreatmentTile` is a plain `StatelessWidget`, so pass the clock down from `_ActiveTreatmentsCard` (a `ConsumerWidget`) rather than converting it — the clock sweep forbids reaching for `DateTime.now()` here:

```dart
              children: treatments.take(3).map((t) {
                return _ActiveTreatmentTile(
                  treatment: t,
                  now: ref.watch(nowProvider)(),
                );
              }).toList(),
```

```dart
class _ActiveTreatmentTile extends StatelessWidget {
  const _ActiveTreatmentTile({required this.treatment, required this.now});
  final Treatment treatment;
  final DateTime now;
```

and inside the subtitle `Column`, after the `startedOn` `Text`:

```dart
          if (treatment.isSickLeaveOpen) ...[
            const SizedBox(height: 4),
            TagChip(
              label: '${l10n.sickLeave} · ${l10n.sickLeaveDay(treatment.sickLeaveDaysAt(now)!)}',
              fontSize: 10,
              icon: Icons.work_off,
            ),
          ],
```

**The Home goldens must stay byte-identical.** `goldenTreatments` (`test/goldens/golden_config.dart`) holds one treatment, `Influenza`, with **no** sick-leave data, so `isSickLeaveOpen` is false and nothing new paints. This is additive and invisible to the fixture.

- [ ] **Step 8: Run the tests to verify they pass, and confirm the goldens did not move**

Run: `fvm flutter test test/presentation/screens/ test/goldens/`
Expected: PASS. Then `git status --short test/goldens/` must show **no** modified PNG. **Never run `--update-goldens` in this task.**

- [ ] **Step 9: Run the guards and the full suite**

Run: `fvm flutter gen-l10n && git diff --exit-code -- lib/l10n/generated && cat untranslated.txt && fvm flutter test && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed .`
Expected: no generated diff, `untranslated.txt` = `{}`, all green.

- [ ] **Step 10: Commit**

```bash
git add lib/presentation/screens/treatment/ lib/presentation/screens/home/home_screen.dart \
  lib/l10n/app_en.arb lib/l10n/app_de.arb lib/l10n/app_it.arb lib/l10n/generated/ \
  test/presentation/screens/add_treatment_screen_test.dart \
  test/presentation/screens/treatment_detail_screen_test.dart \
  test/presentation/screens/treatment_list_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(treatment): record and show the sick leave of an illness episode

Collapsible Krankenstand section in the form, a block on the detail, a
badge on the list and Home tiles, and the doctor is searchable.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 5: Ending the treatment also closes the sick leave

**Files:**
- Modify: `lib/domain/repositories/treatment_repository.dart`
- Modify: `lib/data/repositories/treatment_repository_impl.dart`
- Modify: `lib/presentation/providers/treatment_providers.dart`
- Create: `lib/presentation/screens/treatment/end_treatment_dialog.dart`
- Modify: `lib/presentation/screens/treatment/treatment_detail_screen.dart`, `treatment_list_screen.dart`
- Modify: `lib/l10n/app_{en,de,it}.arb`
- Test: `test/data/repositories/treatment_repository_test.dart` (add), `test/presentation/screens/treatment_detail_screen_test.dart` (add)

**Interfaces:**
- Consumes: `Treatment.isSickLeaveOpen` (Task 1), `TreatmentModel.copyWith` (Task 3).
- Produces:
  - `Future<Result<Treatment>> endTreatment(String id, {bool endSickLeave = false})` on `TreatmentRepository` and its impl.
  - `Future<void> endTreatment(String id, {bool endSickLeave = false})` on `TreatmentListNotifier`.
  - `Future<bool> confirmAndEndTreatment(BuildContext context, WidgetRef ref, Treatment treatment)` in `end_treatment_dialog.dart` — shows the confirm dialog (with the checkbox when `treatment.isSickLeaveOpen`), ends the treatment on confirm, and returns whether it ended.
  - l10n key `sickLeaveEndToday`.

- [ ] **Step 1: Add the l10n key**

en (after `"sickLeaveToBeforeFrom"`): `"sickLeaveEndToday": "Also end sick leave today",`
de: `"sickLeaveEndToday": "Krankenstand ebenfalls heute beenden",`
it: `"sickLeaveEndToday": "Termina anche la malattia oggi",`

Run `fvm flutter gen-l10n`.

- [ ] **Step 2: Write the failing tests**

Add to `test/data/repositories/treatment_repository_test.dart`:

```dart
  test('endSickLeave closes an open leave at today', () async {
    await seedEpisode(); // open leave from 2026-03-03, no end
    final result = await repo.endTreatment('t1', endSickLeave: true);
    expect(result.isSuccess, isTrue);

    final stored = (await local.getTreatmentById('t1'))!;
    expect(stored.sickLeaveTo, isNotNull);
    expect(stored.sickLeaveTo, stored.endDate);
    expect(stored.sickLeaveFrom, DateTime(2026, 3, 3));
  });

  test('endSickLeave defaults to false and leaves the leave open', () async {
    await seedEpisode();
    await repo.endTreatment('t1');
    final stored = (await local.getTreatmentById('t1'))!;
    expect(stored.sickLeaveTo, isNull);
  });

  test('endSickLeave never reopens or moves an already closed leave', () async {
    await local.upsert(
      TreatmentModel(
        id: 't2',
        name: 'Grippe',
        startDate: DateTime(2026, 2, 1),
        sickLeaveFrom: DateTime(2026, 2, 2),
        sickLeaveTo: DateTime(2026, 2, 5),
      ),
      syncStatus: SyncStatus.synced,
    );
    await repo.endTreatment('t2', endSickLeave: true);
    final stored = (await local.getTreatmentById('t2'))!;
    expect(stored.sickLeaveTo, DateTime(2026, 2, 5));
  });
```

Add to `test/presentation/screens/treatment_detail_screen_test.dart`: a treatment with an open sick leave shows `find.text('Also end sick leave today')` in the End dialog and, after confirming, its stored `sickLeaveTo` is non-null; a treatment **without** a sick leave shows an End dialog with **no** checkbox and ends normally.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `fvm flutter test test/data/repositories/treatment_repository_test.dart`
Expected: FAIL — `No named parameter with the name 'endSickLeave'`.

- [ ] **Step 4: Thread `endSickLeave` through the data layer**

`lib/domain/repositories/treatment_repository.dart`:

```dart
  /// End a treatment (set isActive to false, set endDate).
  ///
  /// When [endSickLeave] is true and the treatment has an **open** sick
  /// leave, the leave is closed on the same day. An already closed leave is
  /// never moved.
  Future<Result<Treatment>> endTreatment(String id, {bool endSickLeave = false});
```

`lib/data/repositories/treatment_repository_impl.dart` — in the body written in Task 3, replace the `copyWith` call:

```dart
      final closesLeave = endSickLeave && existing.toDomain().isSickLeaveOpen;
      final ended = existing.copyWith(
        endDate: now,
        isActive: false,
        sickLeaveTo: closesLeave ? now : null,
        updatedAt: nextUpdatedAt(existing.updatedAt, now),
      );
```

(`sickLeaveTo: null` is the no-op case — `copyWith`'s `??` keeps the stored value, which is exactly what "never move a closed leave" means.)

`lib/presentation/providers/treatment_providers.dart`:

```dart
  Future<void> endTreatment(String id, {bool endSickLeave = false}) async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.endTreatment(id, endSickLeave: endSickLeave);
    await result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }
```

- [ ] **Step 5: Add the shared confirm dialog**

Create `lib/presentation/screens/treatment/end_treatment_dialog.dart`:

```dart
/// Medora - Shared "end treatment" confirmation.
///
/// Both the detail screen's overflow menu and the list row's slide action
/// end a treatment, and both must offer to close an open sick leave on the
/// same day — so the dialog lives here rather than twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';

/// Confirms, then ends [treatment]. Returns true when it was ended.
///
/// When the treatment has an open sick leave the dialog carries one extra
/// checkbox, ticked by default; otherwise it is exactly the dialog the app
/// has always shown.
Future<bool> confirmAndEndTreatment(
  BuildContext context,
  WidgetRef ref,
  Treatment treatment,
) async {
  final l10n = AppLocalizations.of(context);
  var endSickLeave = treatment.isSickLeaveOpen;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(l10n.endTreatment),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.endTreatmentConfirm(treatment.name)),
            if (treatment.isSickLeaveOpen)
              CheckboxListTile(
                key: const Key('endSickLeaveCheckbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: endSickLeave,
                onChanged: (v) => setState(() => endSickLeave = v ?? false),
                title: Text(l10n.sickLeaveEndToday),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.endTreatment),
          ),
        ],
      ),
    ),
  );

  if (confirmed != true) return false;
  await ref
      .read(treatmentListProvider.notifier)
      .endTreatment(treatment.id, endSickLeave: endSickLeave);
  return true;
}
```

- [ ] **Step 6: Use it from both screens**

`treatment_detail_screen.dart` — replace the whole `case 'end':` branch of the overflow `onSelected` with:

```dart
                      case 'end':
                        await confirmAndEndTreatment(context, ref, treatment);
```

`treatment_list_screen.dart` — replace the End `SlidableAction`'s `onPressed`:

```dart
                                onPressed: (_) async {
                                  await confirmAndEndTreatment(context, ref, t);
                                },
```

This adds a confirmation to the slide action, which previously ended a treatment with no confirmation at all — deliberate: it is the same destructive write, and without the dialog there is nowhere to offer the checkbox.

Import `end_treatment_dialog.dart` in both.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `fvm flutter test test/data/repositories/ test/presentation/screens/`
Expected: PASS.

- [ ] **Step 8: Run the full suite and guards**

Run: `fvm flutter test && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed . && cat untranslated.txt`
Expected: green, `{}`, goldens unmodified.

- [ ] **Step 9: Commit**

```bash
git add lib/domain/repositories/treatment_repository.dart \
  lib/data/repositories/treatment_repository_impl.dart \
  lib/presentation/providers/treatment_providers.dart \
  lib/presentation/screens/treatment/ lib/l10n/ \
  test/data/repositories/treatment_repository_test.dart \
  test/presentation/screens/treatment_detail_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(treatment): ending a treatment offers to close its sick leave

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 6: The `'as_needed'` schedule type and logging a dose on the spot

Half of a real illness is "I took one ibuprofen at three because it hurt". Today that is only recordable by inventing a schedule. A third `scheduleType` that generates **no** doses, plus a button that records one, fixes it without a new table: the dose still hangs off a prescription, which is what the `dose_logs` RLS policy walks up to find the owner.

**Files:**
- Modify: `lib/domain/entities/prescription.dart`
- Modify: `lib/presentation/screens/treatment/prescription_sheet.dart`
- Modify: `lib/presentation/screens/treatment/treatment_detail_screen.dart`
- Modify: `lib/presentation/providers/dose_providers.dart`
- Modify: `lib/l10n/app_{en,de,it}.arb`
- Test: `test/domain/entities/prescription_test.dart` (add), `test/presentation/screens/prescription_sheet_test.dart` (add), `test/presentation/providers/dose_providers_test.dart` (add)

**Interfaces:**
- Consumes: `DoseActions` and `_autoDiminish` in `dose_providers.dart`; `DoseLogRepository.addDoseLog(DoseLog)`; `nowProvider`.
- Produces:
  - `Prescription.scheduleType == 'as_needed'` ⇒ `dosesPerDay == 0`, `scheduledDoseTimes == const []`, `previewTimes() == []`.
  - `Future<String?> DoseActions.logAsNeededDose(String prescriptionId)` — inserts one `DoseLog` with `status: DoseStatus.taken` and `scheduledTime == takenTime == ref.read(nowProvider)()`, runs the existing auto-diminish/stock path, refreshes the dose providers, and returns the new dose's id (null on failure).
  - l10n keys `scheduleAsNeeded`, `logDoseNow`, `doseLogged`.

**No migration:** `prescriptions.schedule_type` is a free-text `TEXT NOT NULL DEFAULT 'fixed_interval'` column both locally and in Postgres, and `intervalHours` / `durationDays` keep their NOT NULL defaults (8 / 7) while being hidden in the sheet.

- [ ] **Step 1: Add the l10n keys**

en (after `"timesPerDay": "Times per Day",`):

```json
  "scheduleAsNeeded": "As needed",
  "logDoseNow": "Log dose",
  "doseLogged": "Dose logged",
```

de (after `"timesPerDay": "Mal pro Tag",`):

```json
  "scheduleAsNeeded": "Bei Bedarf",
  "logDoseNow": "Dosis eintragen",
  "doseLogged": "Dosis eingetragen",
```

it (after `"timesPerDay": "Volte al giorno",`):

```json
  "scheduleAsNeeded": "Al bisogno",
  "logDoseNow": "Registra dose",
  "doseLogged": "Dose registrata",
```

Run `fvm flutter gen-l10n`.

- [ ] **Step 2: Write the failing tests**

Add to `test/domain/entities/prescription_test.dart`:

```dart
  group('as_needed', () {
    test('generates no scheduled doses', () {
      expect(_p(scheduleType: 'as_needed').scheduledDoseTimes, isEmpty);
    });

    test('dosesPerDay is zero', () {
      expect(_p(scheduleType: 'as_needed').dosesPerDay, 0);
    });

    test('previewTimes is empty', () {
      expect(_p(scheduleType: 'as_needed').previewTimes(), isEmpty);
    });

    test('ignores interval and duration entirely', () {
      final p = _p(scheduleType: 'as_needed', intervalHours: 4, durationDays: 30);
      expect(p.scheduledDoseTimes, isEmpty);
      expect(p.dosesPerDay, 0);
    });
  });
```

Add to `test/presentation/providers/dose_providers_test.dart`:

```dart
  test('logAsNeededDose records one taken dose at now', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final before = await DoseLogLocalDatasource()
        .getDoseLogsByPrescription(seeded.prescriptionId);

    final id = await c.read(doseActionsProvider).logAsNeededDose(
      seeded.prescriptionId,
    );
    expect(id, isNotNull);

    final after = await DoseLogLocalDatasource()
        .getDoseLogsByPrescription(seeded.prescriptionId);
    expect(after.length, before.length + 1);

    final logged = after.firstWhere((d) => d.id == id);
    expect(logged.status, DoseStatus.taken);
    expect(logged.takenTime, isNotNull);
    expect(logged.scheduledTime, logged.takenTime);
  });
```

> Pin `nowProvider` in that container (the file already builds one in `setUp`) and assert `logged.takenTime` equals the pinned value, so the test proves the clock seam is used rather than `DateTime.now()`.

Add to `test/presentation/screens/prescription_sheet_test.dart`: selecting the **As needed** segment hides `Key('intervalHoursField')` and `Key('durationDaysField')`; saving stores `schedule_type = 'as_needed'`; and `dose_logs` for that prescription stays **empty** after the save.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `fvm flutter test test/domain/entities/prescription_test.dart`
Expected: FAIL — `scheduledDoseTimes` returns 21 fixed-interval times and `dosesPerDay` returns 3, because `'as_needed'` currently falls into the fixed-interval branch.

- [ ] **Step 4: Add the entity branches**

In `lib/domain/entities/prescription.dart`, update the doc comment and both getters:

```dart
  /// 'fixed_interval', 'times_per_day' or 'as_needed'.
  ///
  /// An 'as_needed' prescription ("bei Bedarf") has no schedule at all: it
  /// generates no doses and raises no reminders, and each intake is
  /// recorded when it happens.
  final String scheduleType;
```

```dart
  /// Number of doses per day. Zero for an as-needed prescription.
  int get dosesPerDay {
    if (scheduleType == 'as_needed') return 0;
    if (scheduleType == 'times_per_day' && scheduleTimes != null) {
      return scheduleTimes!.length;
    }
    return (24 / (intervalHours < 1 ? 1 : intervalHours)).ceil();
  }
```

and as the first statement of `scheduledDoseTimes`:

```dart
    // An as-needed prescription has no schedule: no generated doses, and
    // therefore no pending doses for ReminderScheduler to find.
    if (scheduleType == 'as_needed') return const [];
```

(`previewTimes()` needs no change: `.take(0)` on an empty list is empty.)

- [ ] **Step 5: Add the third segment to the sheet**

In `lib/presentation/screens/treatment/prescription_sheet.dart`, `_buildScheduleSection`, add a third `ButtonSegment` after the `times_per_day` one:

```dart
            ButtonSegment(
              value: 'as_needed',
              label: Text(
                l10n.scheduleAsNeeded,
                style: const TextStyle(fontSize: 12),
              ),
              icon: const Icon(Icons.touch_app, size: 16),
            ),
```

The existing `if (_scheduleType == 'fixed_interval') …` and `if (_scheduleType == 'times_per_day') …` guards already hide the interval preview and the times picker for the new value. Find the call site of `_buildDurationField(l10n)` in `build` and wrap it so an as-needed prescription shows no duration:

```dart
        if (_scheduleType != 'as_needed') ...[
          _buildDurationField(l10n),
          const SizedBox(height: 16),
        ],
```

Match the surrounding spacing of the call site you actually find; the point is that neither `Key('intervalHoursField')` nor `Key('durationDaysField')` is mounted for `'as_needed'`, so neither validator can run.

`_save` needs no change: `interval` keeps its parsed-or-8 default, `durationDays` its parsed-or-7, and `scheduleTimes` is already null for anything but `times_per_day`.

- [ ] **Step 6: Add `logAsNeededDose`**

In `lib/presentation/providers/dose_providers.dart`, add to `DoseActions` (it already holds `_ref`, so the clock comes from `nowProvider` and the clock sweep stays green):

```dart
  /// Records one as-needed dose as taken right now.
  ///
  /// An 'as_needed' prescription generates no scheduled doses, so there is
  /// nothing to tick off: this inserts the dose that just happened, with
  /// `scheduledTime == takenTime == now`, and runs the same
  /// auto-diminish/refresh path a tapped dose does. Returns the new dose's
  /// id, or null when the write failed.
  Future<String?> logAsNeededDose(String prescriptionId) async {
    final now = _ref.read(nowProvider)();
    final dose = DoseLog(
      id: const Uuid().v4(),
      prescriptionId: prescriptionId,
      scheduledTime: now,
      takenTime: now,
      status: DoseStatus.taken,
      createdAt: now,
      updatedAt: now,
    );
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.addDoseLog(dose);
    if (!result.isSuccess) return null;
    await _autoDiminish(_ref, dose.id);
    await _refresh();
    return dose.id;
  }
```

Add `import 'package:uuid/uuid.dart';` to the file.

- [ ] **Step 7: Surface it on the detail screen**

In `treatment_detail_screen.dart`, `_prescriptionSummary` gains a first branch:

```dart
    if (p.scheduleType == 'as_needed') {
      return '$dosageText · ${l10n.scheduleAsNeeded}';
    }
```

and the prescription `ListTile`'s subtitle `Column` gains, after the summary `Text`:

```dart
                                if (p.scheduleType == 'as_needed' &&
                                    p.isActive)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      key: Key('logDose_${p.id}'),
                                      onPressed: () async {
                                        final id = await ref
                                            .read(doseActionsProvider)
                                            .logAsNeededDose(p.id);
                                        if (!context.mounted) return;
                                        if (id != null) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(l10n.doseLogged),
                                            ),
                                          );
                                        }
                                      },
                                      icon: const Icon(Icons.add_circle_outline, size: 18),
                                      label: Text(l10n.logDoseNow),
                                    ),
                                  ),
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `fvm flutter test test/domain/entities/prescription_test.dart test/presentation/providers/dose_providers_test.dart test/presentation/screens/prescription_sheet_test.dart`
Expected: PASS.

- [ ] **Step 9: Prove the reminder path stays quiet**

Run: `fvm flutter test test/services/reminder_scheduler_test.dart test/services/dose_maintenance_service_test.dart`
Expected: PASS unchanged. (`ReminderScheduler` only loads *pending* doses and an as-needed prescription never has one; `markOverduePendingAsMissed` likewise only touches pending rows.)

- [ ] **Step 10: Full suite, guards, commit**

Run: `fvm flutter test && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed . && cat untranslated.txt`

```bash
git add lib/domain/entities/prescription.dart lib/presentation/ lib/l10n/ \
  test/domain/entities/prescription_test.dart \
  test/presentation/providers/dose_providers_test.dart \
  test/presentation/screens/prescription_sheet_test.dart
git commit -m "$(cat <<'EOF'
feat(prescription): as-needed schedule with a log-a-dose-now button

'as_needed' generates no doses and no reminders; each intake is recorded
when it happens, through the existing auto-diminish and refresh path.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Task 7: The episode's medication list, and sharing one episode as text

One query, three consumers: the per-prescription intake count on the detail, the shared text, and (already) the CSV. Nothing is retyped — the medicines of an episode *are* its prescriptions and the dose rows they produced.

**Files:**
- Modify: `lib/data/datasources/dose_log_local_datasource.dart`
- Modify: `lib/domain/repositories/dose_log_repository.dart`, `lib/data/repositories/dose_log_repository_impl.dart`
- Modify: `test/helpers/failing_dose_repo.dart` (add the new override)
- Modify: `lib/presentation/providers/dose_providers.dart`
- Modify: `lib/services/export_service.dart`
- Modify: `lib/presentation/screens/treatment/treatment_detail_screen.dart`
- Modify: `lib/l10n/app_{en,de,it}.arb`
- Test: `test/data/datasources/dose_log_local_datasource_test.dart` (add), `test/services/export_service_test.dart` (add), `test/presentation/screens/treatment_detail_screen_test.dart` (add)

**Interfaces:**
- Consumes: `_joinQuery` and `_dedupeById` in `DoseLogLocalDatasource`; `doseDataVersionProvider`; `prescriptionsByTreatmentProvider`; `prescriptionDosageLabel(AppLocalizations, Prescription, {String? medicationUnit})`; `PlatformCapabilities.hasFileShare`; `Prescription.scheduledDoseTimes` (Task 6 makes this empty for as-needed).
- Produces:
  - `Future<List<DoseLogModel>> DoseLogLocalDatasource.getDoseLogsByTreatment(String treatmentId)`
  - `Future<Result<List<DoseLog>>> DoseLogRepository.getDoseLogsByTreatment(String treatmentId)`
  - `final doseLogsByTreatmentProvider = FutureProvider.family<List<DoseLog>, String>(…)`
  - `class EpisodeLabels` with `factory EpisodeLabels.fromL10n(AppLocalizations l10n)`
  - `String buildEpisodeSummary({required Treatment treatment, required List<Prescription> prescriptions, required List<DoseLog> doses, required EpisodeLabels labels, required DateTime now, required String Function(Prescription) dosageText})`
  - `ExportLabels` gains `sickLeave`, `sickLeaveFrom`, `sickLeaveTo`, `sickLeaveRef`, `doctor`; `exportTreatmentsCSV` gains four columns.
  - l10n keys `illness`, `dosesTakenOfPlanned`, `dosesTakenAsNeeded`, `shareEpisode`.

**Layering note:** `prescriptionDosageLabel` lives in `lib/presentation/formatters.dart`, and `lib/services` must not import `lib/presentation`. `buildEpisodeSummary` therefore takes a `dosageText` callback, which the detail screen supplies as `(p) => prescriptionDosageLabel(l10n, p)`. The builder stays pure and unit-testable, and the dosage formatting stays in exactly one place.

- [ ] **Step 1: Add the l10n keys**

en (after `"ongoing": "Ongoing",` block added in Task 4):

```json
  "illness": "Illness",
  "dosesTakenOfPlanned": "{taken} of {total} taken",
  "@dosesTakenOfPlanned": {
    "placeholders": {
      "taken": { "type": "int" },
      "total": { "type": "int" }
    }
  },
  "dosesTakenAsNeeded": "{taken} taken",
  "@dosesTakenAsNeeded": {
    "placeholders": {
      "taken": { "type": "int" }
    }
  },
  "shareEpisode": "Share record",
```

de:

```json
  "illness": "Krankheit",
  "dosesTakenOfPlanned": "{taken} von {total} eingenommen",
  "dosesTakenAsNeeded": "{taken} eingenommen",
  "shareEpisode": "Verlauf teilen",
```

it:

```json
  "illness": "Malattia",
  "dosesTakenOfPlanned": "{taken} di {total} assunte",
  "dosesTakenAsNeeded": "{taken} assunte",
  "shareEpisode": "Condividi resoconto",
```

> `sickLeave` and `illness` are both `Malattia` in Italian. They never appear in the same view except the share text, where the first is prefixed by the treatment's own name — acceptable; if it ever grates, the sick-leave label becomes *Certificato di malattia*.

Run `fvm flutter gen-l10n`.

- [ ] **Step 2: Write the failing tests**

Add to `test/data/datasources/dose_log_local_datasource_test.dart`:

```dart
  test('getDoseLogsByTreatment returns every dose under the treatment', () async {
    final db = await AppDatabase.instance.database;
    final a = await seedPrescription(db, medicationName: 'Tachipirina');
    await seedDoseLog(db, a.prescriptionId, DateTime(2026, 3, 1, 8), status: 'taken');
    await seedDoseLog(db, a.prescriptionId, DateTime(2026, 3, 1, 16), status: 'skipped');
    // A second, unrelated treatment must not leak in.
    final b = await seedPrescription(db, medicationName: 'Moment');
    await seedDoseLog(db, b.prescriptionId, DateTime(2026, 3, 1, 9), status: 'taken');

    final doses = await DoseLogLocalDatasource().getDoseLogsByTreatment(a.treatmentId);

    expect(doses.length, 2);
    expect(doses.every((d) => d.prescriptionId == a.prescriptionId), isTrue);
    // Ordered oldest first, and the join fields are populated.
    expect(doses.first.scheduledTime, DateTime(2026, 3, 1, 8));
    expect(doses.first.medicationName, 'Tachipirina');
  });

  test('getDoseLogsByTreatment is empty for a treatment with no doses', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    expect(
      await DoseLogLocalDatasource().getDoseLogsByTreatment(seeded.treatmentId),
      isEmpty,
    );
  });
```

Add to `test/services/export_service_test.dart`:

```dart
  test('the episode summary lists the illness, the sick leave and the medicines', () {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final labels = EpisodeLabels.fromL10n(l10n);
    final treatment = Treatment(
      id: 't1',
      name: 'Stirnhöhlenentzündung',
      symptomTags: const ['Kopfschmerzen', 'Fieber'],
      startDate: DateTime(2026, 3, 2),
      endDate: DateTime(2026, 3, 11),
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveTo: DateTime(2026, 3, 9),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
      notes: 'ging langsam weg',
    );
    final scheduled = Prescription(
      id: 'p1',
      treatmentId: 't1',
      medicationId: 'm1',
      dosage: '1 tablets',
      dosageAmount: 1,
      intervalHours: 8,
      durationDays: 5,
      startTime: DateTime(2026, 3, 3, 8),
      scheduleType: 'times_per_day',
      scheduleTimes: const ['08:00', '14:00', '20:00'],
      medicationName: 'Ibuprofen 400',
    );
    final asNeeded = Prescription(
      id: 'p2',
      treatmentId: 't1',
      medicationId: 'm2',
      dosage: '1 tablets',
      dosageAmount: 1,
      startTime: DateTime(2026, 3, 3, 8),
      scheduleType: 'as_needed',
      medicationName: 'Tachipirina 1000',
    );

    final text = buildEpisodeSummary(
      treatment: treatment,
      prescriptions: [scheduled, asNeeded],
      doses: [
        for (var i = 0; i < 14; i++)
          DoseLog(
            id: 's$i',
            prescriptionId: 'p1',
            scheduledTime: DateTime(2026, 3, 3, 8).add(Duration(hours: 8 * i)),
            status: DoseStatus.taken,
          ),
        for (var i = 0; i < 3; i++)
          DoseLog(
            id: 'a$i',
            prescriptionId: 'p2',
            scheduledTime: DateTime(2026, 3, 4, 15).add(Duration(days: i)),
            status: DoseStatus.taken,
          ),
      ],
      labels: labels,
      now: DateTime(2026, 3, 12),
      dosageText: (p) => '1 Tablette',
    );

    expect(text, startsWith('Stirnhöhlenentzündung\n'));
    expect(text, contains('Krankenstand: '));
    expect(text, contains('(7 Tage)'));
    expect(text, contains('Bescheinigungsnummer: 1234567890'));
    expect(text, contains('Ärztin/Arzt: Dr. Rossi, Bozen'));
    expect(text, contains('Ibuprofen 400'));
    expect(text, contains('14 von 15 eingenommen'));
    expect(text, contains('Tachipirina 1000'));
    expect(text, contains('Bei Bedarf'));
    expect(text, contains('3 eingenommen'));
    expect(text, contains('ging langsam weg'));
  });

  test('a treatment with no sick leave omits those lines entirely', () {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final text = buildEpisodeSummary(
      treatment: Treatment(id: 't2', name: 'Vitamin D', startDate: DateTime(2026, 3, 2)),
      prescriptions: const [],
      doses: const [],
      labels: EpisodeLabels.fromL10n(l10n),
      now: DateTime(2026, 3, 12),
      dosageText: (p) => '',
    );
    expect(text, contains('Vitamin D'));
    expect(text, isNot(contains('Krankenstand')));
    expect(text, isNot(contains('Bescheinigungsnummer')));
    expect(text, isNot(contains('Ärztin/Arzt')));
  });

  test('the treatment CSV carries the sick-leave columns', () {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final labels = ExportLabels.fromL10n(l10n);
    expect(labels.sickLeaveFrom, l10n.sickLeaveFrom);
    expect(labels.sickLeaveTo, l10n.sickLeaveTo);
    expect(labels.sickLeaveRef, l10n.sickLeaveRef);
    expect(labels.doctor, l10n.doctorLabel);
  });
```

Add to `test/presentation/screens/treatment_detail_screen_test.dart`: a scheduled prescription with 15 planned doses of which 14 are taken renders `14 of 15 taken`; an as-needed prescription with 3 taken doses renders `3 taken`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `fvm flutter test test/data/datasources/dose_log_local_datasource_test.dart test/services/export_service_test.dart`
Expected: FAIL — `getDoseLogsByTreatment` and `buildEpisodeSummary` are not defined.

- [ ] **Step 4: Add the treatment-scoped dose query**

In `lib/data/datasources/dose_log_local_datasource.dart`, next to `getDoseLogsByPrescription`:

```dart
  /// Every dose logged under [treatmentId]'s prescriptions, oldest first.
  ///
  /// This is the episode's real intake record: it is derived from the dose
  /// history the user already produces day by day, never retyped.
  Future<List<DoseLogModel>> getDoseLogsByTreatment(String treatmentId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE p.treatment_id = ? AND d.sync_status != ? '
      'ORDER BY d.scheduled_time ASC',
      [treatmentId, SyncStatus.pendingDelete],
    );
    return _dedupeById(rows).map(_fromRow).toList();
  }
```

In `lib/domain/repositories/dose_log_repository.dart`, after `getDoseLogsByPrescription`:

```dart
  /// Get every dose log under a treatment's prescriptions, oldest first.
  Future<Result<List<DoseLog>>> getDoseLogsByTreatment(String treatmentId);
```

In `lib/data/repositories/dose_log_repository_impl.dart`:

```dart
  @override
  Future<Result<List<DoseLog>>> getDoseLogsByTreatment(String treatmentId) async {
    try {
      final models = await localDatasource.getDoseLogsByTreatment(treatmentId);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load dose logs: $e', st);
    }
  }
```

`test/helpers/failing_dose_repo.dart` implements `DoseLogRepository`; add the matching override there (returning a failure, like its neighbours) or `analyze` will fail on a missing concrete member.

In `lib/presentation/providers/dose_providers.dart`, next to `doseLogsByPrescriptionProvider`:

```dart
/// Every dose logged under a treatment, oldest first. Re-fetches when
/// [doseDataVersionProvider] changes, so logging an as-needed dose updates
/// the counts without a manual invalidate.
final doseLogsByTreatmentProvider =
    FutureProvider.family<List<DoseLog>, String>((ref, treatmentId) async {
      ref.watch(doseDataVersionProvider);
      final repo = ref.watch(doseLogRepositoryProvider);
      final result = await repo.getDoseLogsByTreatment(treatmentId);
      return result.when(
        success: (data) => data,
        failure: (msg) => throw Exception(msg),
      );
    });
```

- [ ] **Step 5: Add `EpisodeLabels` and `buildEpisodeSummary`**

In `lib/services/export_service.dart`, after the `ExportLabels` class:

```dart
/// Localized labels for the one-episode text share, mirroring
/// [ExportLabels.fromL10n] so this service stays free of [BuildContext].
class EpisodeLabels {
  const EpisodeLabels({
    required this.illness,
    required this.sickLeave,
    required this.sickLeaveRef,
    required this.doctor,
    required this.symptoms,
    required this.medications,
    required this.notes,
    required this.ongoing,
    required this.asNeeded,
    required this.days,
    required this.takenOfPlanned,
    required this.takenAsNeeded,
  });

  factory EpisodeLabels.fromL10n(AppLocalizations l10n) => EpisodeLabels(
    illness: l10n.illness,
    sickLeave: l10n.sickLeave,
    sickLeaveRef: l10n.sickLeaveRef,
    doctor: l10n.doctorLabel,
    symptoms: l10n.symptoms,
    medications: l10n.medications,
    notes: l10n.notes,
    ongoing: l10n.ongoing,
    asNeeded: l10n.scheduleAsNeeded,
    days: l10n.sickLeaveDays,
    takenOfPlanned: l10n.dosesTakenOfPlanned,
    takenAsNeeded: l10n.dosesTakenAsNeeded,
  );

  final String illness;
  final String sickLeave;
  final String sickLeaveRef;
  final String doctor;
  final String symptoms;
  final String medications;
  final String notes;
  final String ongoing;
  final String asNeeded;
  final String Function(int days) days;
  final String Function(int taken, int total) takenOfPlanned;
  final String Function(int taken) takenAsNeeded;
}

/// A plain-text record of one illness episode, for
/// `SharePlus.instance.share(ShareParams(text: …))`.
///
/// One episode, never the cabinet: the user hands an employer the dates,
/// not their whole medicine history. Pure, so it is unit-testable without a
/// share sheet. [dosageText] formats a prescription's dose — the caller
/// passes `prescriptionDosageLabel`, which lives in the presentation layer.
@visibleForTesting
String buildEpisodeSummary({
  required Treatment treatment,
  required List<Prescription> prescriptions,
  required List<DoseLog> doses,
  required EpisodeLabels labels,
  required DateTime now,
  required String Function(Prescription) dosageText,
}) {
  final lines = <String>[treatment.name];

  lines.add(
    '${labels.illness}: ${treatment.startDate.formatted} – '
    '${treatment.endDate.formattedOr(labels.ongoing)}',
  );

  if (treatment.hasSickLeave) {
    final days = treatment.sickLeaveDaysAt(now)!;
    lines.add(
      '${labels.sickLeave}: ${treatment.sickLeaveFrom!.formatted} – '
      '${treatment.sickLeaveTo.formattedOr(labels.ongoing)} '
      '(${labels.days(days)})',
    );
  }
  if (treatment.sickLeaveRef != null) {
    lines.add('${labels.sickLeaveRef}: ${treatment.sickLeaveRef}');
  }
  if (treatment.doctor != null) {
    lines.add('${labels.doctor}: ${treatment.doctor}');
  }
  if (treatment.symptomTags.isNotEmpty) {
    lines.add('${labels.symptoms}: ${treatment.symptomTags.join(', ')}');
  }

  if (prescriptions.isNotEmpty) {
    lines.add('${labels.medications}:');
    for (final p in prescriptions) {
      final taken = doses
          .where((d) => d.prescriptionId == p.id && d.status == DoseStatus.taken)
          .length;
      final planned = p.scheduledDoseTimes.length;
      final count = p.scheduleType == 'as_needed'
          ? labels.takenAsNeeded(taken)
          : labels.takenOfPlanned(taken, planned);
      final schedule = p.scheduleType == 'as_needed' ? labels.asNeeded : '';
      final parts = <String>[
        dosageText(p),
        if (schedule.isNotEmpty) schedule,
      ].where((s) => s.isNotEmpty).join(', ');
      lines.add('  ${p.medicationName ?? ''} — $parts — $count');
    }
  }

  if (treatment.notes != null && treatment.notes!.isNotEmpty) {
    lines.add('${labels.notes}: ${treatment.notes}');
  }

  return lines.join('\n');
}
```

Add the `Prescription` import to the file.

- [ ] **Step 6: Add the four CSV columns**

In `ExportLabels`: add `sickLeave`, `sickLeaveFrom`, `sickLeaveTo`, `sickLeaveRef`, `doctor` to the constructor, the `fromL10n` factory (`sickLeaveFrom: l10n.sickLeaveFrom` … `doctor: l10n.doctorLabel`) and the field list. In `exportTreatmentsCSV`, extend the headers and each row:

```dart
      labels.sickLeaveFrom,
      labels.sickLeaveTo,
      labels.sickLeaveRef,
      labels.doctor,
```

```dart
        t.sickLeaveFrom != null ? t.sickLeaveFrom!.formatted : '',
        t.sickLeaveTo != null ? t.sickLeaveTo!.formatted : '',
        t.sickLeaveRef ?? '',
        t.doctor ?? '',
```

- [ ] **Step 7: Show the counts and the share action**

In `treatment_detail_screen.dart`, watch the new provider next to the prescriptions one:

```dart
    final episodeDosesAsync = ref.watch(
      doseLogsByTreatmentProvider(widget.treatmentId),
    );
```

and add the count under each prescription's summary line (after the `Text(_prescriptionSummary(l10n, p))`):

```dart
                                Text(
                                  _doseCount(l10n, p, episodeDosesAsync.value ?? const []),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.colors.onSurfaceVariant,
                                  ),
                                ),
```

```dart
  String _doseCount(AppLocalizations l10n, Prescription p, List<DoseLog> doses) {
    final taken = doses
        .where((d) => d.prescriptionId == p.id && d.status == DoseStatus.taken)
        .length;
    return p.scheduleType == 'as_needed'
        ? l10n.dosesTakenAsNeeded(taken)
        : l10n.dosesTakenOfPlanned(taken, p.scheduledDoseTimes.length);
  }
```

Add a `'share'` entry to the app-bar `PopupMenuButton`, above `'end'`, gated on file share:

```dart
                    if (ref.watch(platformCapabilitiesProvider).hasFileShare)
                      PopupMenuItem(
                        value: 'share',
                        child: ListTile(
                          leading: const Icon(Icons.share),
                          title: Text(l10n.shareEpisode),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
```

and its handler in `onSelected`:

```dart
                      case 'share':
                        final prescriptions =
                            await ref.read(
                              prescriptionsByTreatmentProvider(
                                widget.treatmentId,
                              ).future,
                            );
                        final doses = await ref.read(
                          doseLogsByTreatmentProvider(widget.treatmentId).future,
                        );
                        if (!context.mounted) return;
                        final text = buildEpisodeSummary(
                          treatment: treatment,
                          prescriptions: prescriptions,
                          doses: doses,
                          labels: EpisodeLabels.fromL10n(l10n),
                          now: ref.read(nowProvider)(),
                          dosageText: (p) => prescriptionDosageLabel(l10n, p),
                        );
                        await SharePlus.instance.share(ShareParams(text: text));
```

Imports: `package:share_plus/share_plus.dart`, `package:medora/services/export_service.dart`, `package:medora/core/platform_capabilities.dart`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `fvm flutter test test/data/ test/services/export_service_test.dart test/presentation/screens/treatment_detail_screen_test.dart`
Expected: PASS.

- [ ] **Step 9: Full suite and guards**

Run: `fvm flutter gen-l10n && git diff --exit-code -- lib/l10n/generated && cat untranslated.txt && fvm flutter test && fvm flutter analyze --fatal-infos && fvm dart format --set-exit-if-changed .`
Expected: no generated diff, `{}`, all green, `git status --short test/goldens/` clean.

- [ ] **Step 10: Commit**

```bash
git add lib/data/ lib/domain/repositories/dose_log_repository.dart lib/presentation/ \
  lib/services/export_service.dart lib/l10n/ test/
git commit -m "$(cat <<'EOF'
feat(treatment): derive an episode's medicines and share it as text

One treatment-scoped dose query feeds the per-prescription intake counts,
the plain-text share of a single episode, and four new CSV columns.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Deliberately out of scope

Named so nobody re-litigates them mid-task; each is argued in the design (§11).

1. A separate `SicknessEpisode` entity or table, and renaming `Treatment` anywhere.
2. A photo of the sick note (photos go base64 into the backup envelope, which already has a 150 MB problem).
3. An ICD-10 catalogue or a second `diagnosis` field — the free `name` field is the right granularity.
4. Multiple sick-leave segments per episode (a *Verlängerung*). v1 is one range; a relapse after returning to work is a second episode, which is also how an employer sees it. If it is ever needed it becomes a child table, and nothing built here has to be undone.
5. Symptom severity, daily temperature, a symptom diary.
6. Employer fields, HR workflows, calendar integrations, reminders to send the certificate.
7. **A new Home card or section** — `home_golden_test.dart` asserts `maxScrollExtent == 0` at 964 dp, so any new section breaks the goldens, and Home is being edited on this branch. Task 4 only adds an additive badge to the existing tile.
8. **A per-episode PDF** — decided: plain-text share first. The `pdf` package is already a dependency, so adding one later is cheap; a file to manage is the wrong shape for "send my employer the dates".
9. Renaming or restructuring the Behandlungen tab — decided: it keeps its name. If "Behandlung" ever reads wrong for an illness episode, reword two or three ARB strings (the empty state and the form title are the candidates); do not restructure navigation.
