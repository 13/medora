# Phase 1 — Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the functional bugs found in the audit so reminders, dose status, timestamps, photos and list refreshes behave as designed, with tests for each fix.

**Architecture:** Dose status writes become full-row round trips through the local datasource (clear `taken_time`, write `updated_at`, return the real row). A `ReminderScheduler` owns all notification scheduling (7-day horizon, 60-notification cap, respects the user toggle) behind a small `ReminderPort` interface so it is unit-testable; `ReminderService` implements the port. A `DoseMaintenanceService` marks overdue pending doses as missed. Both run from one `AppStartupTasks` hook on app start and resume. Photos are stored by relative filename via a `PhotoStorage` service with a migration that backfills old absolute paths. `updated_at` is set by repositories on user mutations and preserved on pulls.

**Tech Stack:** Flutter 3.44 (via `fvm`), Dart 3.11, flutter_riverpod 3, sqflite + sqflite_common_ffi (tests), flutter_local_notifications 21, path_provider, shared_preferences.

Spec: `docs/superpowers/specs/2026-09-14-medora-offline-first-overhaul-design.md` — §5 "Phase 1", §4.3 (migration 12), §4.4 (Reminders), §4.5 (Dose maintenance), §8 (grace 2h, horizon 7 days / 60 notifications).

## Global Constraints

- Run every Flutter/Dart command through `fvm`: `fvm flutter …`. Working directory `/home/ben/repo/medora`. Branch off `main` (`e11760b` or later) as `phase1-correctness`.
- Package imports only: `package:medora/...`.
- All user-visible strings via `AppLocalizations` (ARB en/de/it → `fvm flutter gen-l10n`; commit `lib/l10n/generated/*` only in tasks that change ARB; `untranslated.txt` must stay `{}`).
- Reminder horizon: **7 days** ahead; cap **60** pending notifications; two notifications per dose (60 min before, at time); `remindersEnabledProvider == false` ⇒ scheduler only cancels.
- Missed-dose grace: default **120 minutes** after scheduled time, user-configurable (30 / 60 / 120 / 240), applied on app start and on resume.
- Migration 12 adds nothing to the schema that breaks v11 installs; it backfills `medications.image_path` to a bare filename. Never edit migration 11.
- Every task ends with `fvm flutter analyze --fatal-infos` → `No issues found!` and `fvm flutter test` green, then a commit whose message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
  ```
- Test database: `test/helpers/test_database.dart` (`setUpTestDatabase()` / `tearDownTestDatabase()`) gives a fresh in-memory SQLite per test with `PRAGMA foreign_keys = ON` — dose_logs need a prescription, which needs a medication and a treatment (Task 1 adds a seed helper for this).

## File map

| Path | Responsibility |
|---|---|
| `test/helpers/seed.dart` (new) | Insert a medication + treatment + prescription (+ optional dose logs) for datasource/repo tests. |
| `lib/data/datasources/dose_log_local_datasource.dart` | `updateStatus` clears `taken_time`, writes `updated_at`; `getDoseLogById`; `getPendingBetween`; `markOverduePendingAsMissed`. |
| `lib/data/repositories/dose_log_repository_impl.dart` | Status mutations return the real row. |
| `lib/domain/repositories/dose_log_repository.dart` | `getDoseLogById`, `getPendingDoseLogsBetween`, `markOverduePendingAsMissed`. |
| `lib/data/datasources/{medication,treatment,prescription}_local_datasource.dart`, `lib/data/models/prescription_model.dart` | `_toRow` preserves `updated_at` from the model. |
| `lib/data/repositories/{medication,treatment}_repository_impl.dart` | Stamp `updatedAt = now` on user mutations. |
| `lib/services/photo_storage.dart` (new) | Save picked photo by filename; resolve filename → `File`; delete all. |
| `lib/data/local/migrations.dart` | Migration 12: backfill `image_path` to basename. |
| `lib/services/reminder_port.dart` (new) | `abstract class ReminderPort { cancelAll(); scheduleForDose(...); }`. |
| `lib/services/reminder_service.dart` | Implements `ReminderPort`; stable FNV-1a ids. |
| `lib/services/reminder_scheduler.dart` (new) | `reconcile()`: 7-day horizon, 60 cap, toggle. |
| `lib/services/dose_maintenance_service.dart` (new) | `markOverdueAsMissed(grace)`. |
| `lib/services/app_startup_tasks.dart` (new) | Runs maintenance → refresh doses → reminders reconcile → (cloud) sync. |
| `lib/presentation/providers/settings_providers.dart` | `missedGraceMinutesProvider`. |
| `lib/presentation/providers/providers.dart` | `reminderPortProvider`, `reminderSchedulerProvider`, `doseMaintenanceProvider`, `appStartupTasksProvider`, `syncStartupDelayProvider`. |
| `lib/presentation/providers/dose_providers.dart` | Delegates scheduling to the scheduler; no static flags. |
| `lib/presentation/providers/{medication,treatment}_providers.dart` | No loading flash on mutations; `expiringSoonProvider` excludes expired. |
| `lib/presentation/screens/main_shell_screen.dart` | Lifecycle observer → `AppStartupTasks.run()`. |
| `lib/presentation/screens/settings/settings_screen.dart` | Grace picker; reminders toggle → reconcile; delete-all cancels reminders + deletes photos; cloud turn-off keep/wipe. |
| `lib/presentation/screens/medication/{add,detail}_medication_screen.dart` | Use `PhotoStorage`. |

---

### Task 1: Dose status round trip (clear `taken_time`, write `updated_at`, return the real row) + seed helper

**Files:**
- Create: `test/helpers/seed.dart`
- Modify: `lib/data/datasources/dose_log_local_datasource.dart` (`updateStatus`, add `getDoseLogById`, `_toRow` writes `updated_at`)
- Modify: `lib/domain/repositories/dose_log_repository.dart` (add `getDoseLogById`)
- Modify: `lib/data/repositories/dose_log_repository_impl.dart` (`markDose*` return real rows)
- Test: `test/data/datasources/dose_log_local_datasource_test.dart`, `test/data/repositories/dose_log_repository_test.dart`

**Interfaces:**
- Produces:
  ```dart
  // test/helpers/seed.dart
  class SeededPrescription { final String medicationId, treatmentId, prescriptionId; }
  Future<SeededPrescription> seedPrescription(Database db, {DateTime? startTime, int intervalHours = 8, int durationDays = 2});
  Future<String> seedDoseLog(Database db, String prescriptionId, DateTime scheduledTime, {String status = 'pending', String? id});

  // DoseLogLocalDatasource
  Future<void> updateStatus(String id, String status, {DateTime? takenTime, bool clearTakenTime = false, required String syncStatus});
  Future<DoseLogModel?> getDoseLogById(String id);

  // DoseLogRepository
  Future<Result<DoseLog>> getDoseLogById(String id);
  ```

- [ ] **Step 1: Create the seed helper**

`test/helpers/seed.dart`:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class SeededPrescription {
  const SeededPrescription({
    required this.medicationId,
    required this.treatmentId,
    required this.prescriptionId,
  });
  final String medicationId;
  final String treatmentId;
  final String prescriptionId;
}

/// Inserts one medication, one treatment and one fixed-interval prescription.
Future<SeededPrescription> seedPrescription(
  Database db, {
  DateTime? startTime,
  int intervalHours = 8,
  int durationDays = 2,
  String medicationName = 'Tachipirina',
}) async {
  final medId = _uuid.v4();
  final treatId = _uuid.v4();
  final prescId = _uuid.v4();
  final start = startTime ?? DateTime(2026, 3, 1, 8);
  final now = DateTime.now().toIso8601String();

  await db.insert('medications', {
    'id': medId,
    'name': medicationName,
    'quantity': 10,
    'quantity_unit': 'tablets',
    'minimum_stock_level': 0,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  await db.insert('treatments', {
    'id': treatId,
    'name': 'Flu',
    'start_date': start.toIso8601String().split('T').first,
    'is_active': 1,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  await db.insert('prescriptions', {
    'id': prescId,
    'treatment_id': treatId,
    'medication_id': medId,
    'dosage': '1 tablet',
    'dosage_amount': 1.0,
    'interval_hours': intervalHours,
    'duration_days': durationDays,
    'start_time': start.toIso8601String(),
    'is_active': 1,
    'auto_diminish': 0,
    'created_at': now,
    'updated_at': now,
    'schedule_type': 'fixed_interval',
    'sync_status': 'synced',
  });
  return SeededPrescription(medicationId: medId, treatmentId: treatId, prescriptionId: prescId);
}

/// Inserts one dose log and returns its id.
Future<String> seedDoseLog(
  Database db,
  String prescriptionId,
  DateTime scheduledTime, {
  String status = 'pending',
  String? id,
  DateTime? takenTime,
}) async {
  final doseId = id ?? _uuid.v4();
  final now = DateTime.now().toIso8601String();
  await db.insert('dose_logs', {
    'id': doseId,
    'prescription_id': prescriptionId,
    'scheduled_time': scheduledTime.toIso8601String(),
    'taken_time': takenTime?.toIso8601String(),
    'status': status,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  return doseId;
}
```

- [ ] **Step 2: Write the failing datasource test**

`test/data/datasources/dose_log_local_datasource_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('updateStatus with clearTakenTime nulls taken_time and bumps updated_at', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final taken = DateTime(2026, 3, 1, 8, 5);
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8),
        status: 'taken', takenTime: taken);
    final ds = DoseLogLocalDatasource();

    final before = (await ds.getDoseLogById(id))!;
    expect(before.status, DoseStatus.taken);
    expect(before.takenTime, taken);

    await ds.updateStatus(id, 'pending', clearTakenTime: true, syncStatus: SyncStatus.pendingUpdate);

    final after = (await ds.getDoseLogById(id))!;
    expect(after.status, DoseStatus.pending);
    expect(after.takenTime, isNull);
    expect(after.updatedAt, isNotNull);
    expect(after.updatedAt!.isAfter(before.updatedAt!), isTrue);
  });

  test('updateStatus taken writes taken_time and keeps join fields readable', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, medicationName: 'Moment');
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final ds = DoseLogLocalDatasource();

    final at = DateTime(2026, 3, 1, 8, 10);
    await ds.updateStatus(id, 'taken', takenTime: at, syncStatus: SyncStatus.pendingUpdate);

    final row = (await ds.getDoseLogById(id))!;
    expect(row.status, DoseStatus.taken);
    expect(row.takenTime, at);
    expect(row.medicationName, 'Moment');
    expect(row.prescriptionId, seeded.prescriptionId);
  });

  test('getDoseLogById returns null for unknown id', () async {
    expect(await DoseLogLocalDatasource().getDoseLogById('nope'), isNull);
  });
}
```

Run: `fvm flutter test test/data/datasources/dose_log_local_datasource_test.dart`
Expected: FAIL — `getDoseLogById` undefined; `clearTakenTime` undefined.

- [ ] **Step 3: Implement in `lib/data/datasources/dose_log_local_datasource.dart`**

Replace `updateStatus` with:

```dart
  /// Change a dose's status. Pass [clearTakenTime] to null out `taken_time`
  /// (undo). Always writes `updated_at` so last-write-wins sync can compare.
  Future<void> updateStatus(
    String id,
    String status, {
    DateTime? takenTime,
    bool clearTakenTime = false,
    required String syncStatus,
  }) async {
    final db = await _db;
    final updates = <String, dynamic>{
      'status': status,
      'sync_status': syncStatus,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (clearTakenTime) {
      updates['taken_time'] = null;
    } else if (takenTime != null) {
      updates['taken_time'] = takenTime.toIso8601String();
    }
    await db.update('dose_logs', updates, where: 'id = ?', whereArgs: [id]);
  }
```

Add after `getDoseLogsByPrescription`:

```dart
  /// One dose log with its joined display fields, or null.
  Future<DoseLogModel?> getDoseLogById(String id) async {
    final db = await _db;
    final rows = await db.rawQuery('$_joinQuery WHERE d.id = ? LIMIT 1', [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }
```

In `_toRow`, add `'updated_at': m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),` after the `created_at` entry. In `_fromRow`, add `updatedAt: row['updated_at'] != null ? DateTime.tryParse(row['updated_at'] as String) : null,` after `createdAt`.

- [ ] **Step 4: Write the failing repository test**

`test/data/repositories/dose_log_repository_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  DoseLogRepositoryImpl makeRepo() => DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        remoteDatasource: null,
        prescriptionLocal: PrescriptionLocalDatasource(),
      );

  test('markDoseTaken then markDosePending return real rows and clear taken_time', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, medicationName: 'Brufen');
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final repo = makeRepo();

    final taken = (await repo.markDoseTaken(id)).dataOrNull!;
    expect(taken.id, id);
    expect(taken.prescriptionId, seeded.prescriptionId);
    expect(taken.medicationName, 'Brufen');
    expect(taken.scheduledTime, DateTime(2026, 3, 1, 8));
    expect(taken.status, DoseStatus.taken);
    expect(taken.takenTime, isNotNull);

    final pending = (await repo.markDosePending(id)).dataOrNull!;
    expect(pending.status, DoseStatus.pending);
    expect(pending.takenTime, isNull);
    expect(pending.prescriptionId, seeded.prescriptionId);
  });

  test('markDoseSkipped / markDoseMissed return the stored row', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final repo = makeRepo();

    expect((await repo.markDoseSkipped(id)).dataOrNull!.status, DoseStatus.skipped);
    expect((await repo.markDoseMissed(id)).dataOrNull!.status, DoseStatus.missed);
  });

  test('marking an unknown id fails', () async {
    final result = await makeRepo().markDoseTaken('missing');
    expect(result.isFailure, isTrue);
  });
}
```

Run: `fvm flutter test test/data/repositories/dose_log_repository_test.dart`
Expected: FAIL — `prescriptionId` is `''` and `medicationName` null (fabricated row); unknown id currently "succeeds".

- [ ] **Step 5: Implement real-row returns in `lib/data/repositories/dose_log_repository_impl.dart`**

Add to the interface `lib/domain/repositories/dose_log_repository.dart`:

```dart
  /// One dose log by id.
  Future<Result<DoseLog>> getDoseLogById(String id);
```

In the impl, add:

```dart
  @override
  Future<Result<DoseLog>> getDoseLogById(String id) async {
    try {
      final model = await localDatasource.getDoseLogById(id);
      if (model == null) return const Result.failure('Dose log not found');
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to load dose log: $e', st);
    }
  }

  /// Shared status mutation: update locally, sync in background, return the stored row.
  Future<Result<DoseLog>> _changeStatus(
    String id,
    String status, {
    DateTime? takenTime,
    bool clearTakenTime = false,
  }) async {
    try {
      final existing = await localDatasource.getDoseLogById(id);
      if (existing == null) return const Result.failure('Dose log not found');

      await localDatasource.updateStatus(
        id,
        status,
        takenTime: takenTime,
        clearTakenTime: clearTakenTime,
        syncStatus: SyncStatus.pendingUpdate,
      );
      _syncRemoteInBackground(
        (r) => r.updateDoseLogStatus(id, status, takenTime: clearTakenTime ? null : takenTime),
        id,
      );
      final updated = await localDatasource.getDoseLogById(id);
      return Result.success(updated!.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to mark dose as $status: $e', st);
    }
  }
```

and replace the four `markDose*` bodies:

```dart
  @override
  Future<Result<DoseLog>> markDoseTaken(String id) =>
      _changeStatus(id, 'taken', takenTime: DateTime.now());

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) => _changeStatus(id, 'skipped');

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) => _changeStatus(id, 'missed');

  @override
  Future<Result<DoseLog>> markDosePending(String id) =>
      _changeStatus(id, 'pending', clearTakenTime: true);
```

- [ ] **Step 6: Verify and commit**

Run: `fvm flutter test test/data/` then `fvm flutter analyze --fatal-infos` then `fvm flutter test`.
Expected: all green, `No issues found!`.

```bash
git add test/helpers/seed.dart test/data lib/data/datasources/dose_log_local_datasource.dart lib/data/repositories/dose_log_repository_impl.dart lib/domain/repositories/dose_log_repository.dart
git commit -m "fix(doses): undo clears taken_time; status mutations return the stored row

updateStatus now nulls taken_time on undo and writes updated_at.
markDose* read back the row instead of fabricating one.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 2: `updated_at` semantics — repositories stamp, datasources preserve

**Files:**
- Modify: `lib/data/datasources/medication_local_datasource.dart` (`_toRow`), `treatment_local_datasource.dart` (`_toRow`), `lib/data/models/prescription_model.dart` (`toLocalMap`)
- Modify: `lib/data/repositories/medication_repository_impl.dart`, `treatment_repository_impl.dart`, `prescription_repository_impl.dart` (stamp `updatedAt: now` on add/update/quantity/end)
- Test: `test/data/datasources/updated_at_test.dart`

**Interfaces:** no signature changes. Rule: **datasource `_toRow` writes `model.updatedAt` when present, else `now`; repositories set `updatedAt = DateTime.now()` on every user mutation; sync pulls pass the remote model through unchanged.**

- [ ] **Step 1: Write the failing test**

`test/data/datasources/updated_at_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final remoteStamp = DateTime.utc(2025, 12, 24, 10, 30);

  test('medication upsert preserves an explicit updatedAt (remote pull)', () async {
    final ds = MedicationLocalDatasource();
    await ds.upsert(
      MedicationModel(id: 'm1', name: 'Aspirin', quantity: 1, updatedAt: remoteStamp),
      syncStatus: SyncStatus.synced,
    );
    expect((await ds.getMedicationById('m1'))!.updatedAt, remoteStamp);
  });

  test('treatment upsert preserves an explicit updatedAt', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(id: 't1', name: 'Flu', startDate: DateTime(2026, 3, 1), updatedAt: remoteStamp),
      syncStatus: SyncStatus.synced,
    );
    expect((await ds.getTreatmentById('t1'))!.updatedAt, remoteStamp);
  });

  test('prescription upsert preserves an explicit updatedAt', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final ds = PrescriptionLocalDatasource();
    final existing = (await ds.getPrescriptionById(seeded.prescriptionId))!;
    await ds.upsert(
      PrescriptionModel(
        id: existing.id,
        treatmentId: existing.treatmentId,
        medicationId: existing.medicationId,
        dosage: existing.dosage,
        startTime: existing.startTime,
        updatedAt: remoteStamp,
      ),
      syncStatus: SyncStatus.synced,
    );
    expect((await ds.getPrescriptionById(existing.id))!.updatedAt, remoteStamp);
  });

  test('repository add/update stamps updatedAt with now', () async {
    final repo = MedicationRepositoryImpl(localDatasource: MedicationLocalDatasource(), remoteDatasource: null);
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await repo.addMedication(const Medication(id: 'm2', name: 'Moment', quantity: 3));
    final added = (await repo.getMedicationById('m2')).dataOrNull!;
    expect(added.updatedAt, isNotNull);
    expect(added.updatedAt!.isAfter(before), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.updateQuantity('m2', -1);
    final bumped = (await repo.getMedicationById('m2')).dataOrNull!;
    expect(bumped.updatedAt!.isAfter(added.updatedAt!), isTrue);
  });
}
```

Run: `fvm flutter test test/data/datasources/updated_at_test.dart`
Expected: the three "preserves" tests FAIL (row gets `now`, not `remoteStamp`); the repository test passes already.

- [ ] **Step 2: Datasources preserve the model's timestamp**

`lib/data/datasources/medication_local_datasource.dart` `_toRow`: replace
`'updated_at': DateTime.now().toIso8601String(),` with
`'updated_at': m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),`.

Same replacement in `lib/data/datasources/treatment_local_datasource.dart` `_toRow` and in `lib/data/models/prescription_model.dart` `toLocalMap()` (there the expression is `updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String()`).

Leave the `archiveMedication` / `unarchiveMedication` / `deactivate` / `reactivate` datasource methods as they are — they are user mutations and already write `now`.

- [ ] **Step 3: Repositories stamp `now` on user mutations**

`lib/data/repositories/medication_repository_impl.dart`:
- `addMedication`: `final model = MedicationModel.fromDomain(medication.copyWith(updatedAt: DateTime.now(), createdAt: medication.createdAt ?? DateTime.now()));`
- `updateMedication`: `final model = MedicationModel.fromDomain(medication.copyWith(updatedAt: DateTime.now()));`
- `updateQuantity`: already builds `updatedAt: DateTime.now()` — keep.

`lib/data/repositories/treatment_repository_impl.dart`:
- `addTreatment`: `TreatmentModel.fromDomain(treatment.copyWith(updatedAt: DateTime.now(), createdAt: treatment.createdAt ?? DateTime.now()))`
- `updateTreatment`: `TreatmentModel.fromDomain(treatment.copyWith(updatedAt: DateTime.now()))`
- `endTreatment`: add `updatedAt: DateTime.now(),` to the `TreatmentModel(...)` literal.

`lib/data/repositories/prescription_repository_impl.dart`: `addPrescription` and `updatePrescription` already `copyWith(updatedAt: now)` — keep.

- [ ] **Step 4: Verify and commit**

Run: `fvm flutter test test/data/ && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: green / `No issues found!`.

```bash
git add lib/data test/data/datasources/updated_at_test.dart
git commit -m "fix(sync): preserve updated_at on local writes; repositories stamp user mutations

Pulled rows keep the remote timestamp so last-write-wins is meaningful.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---
### Task 3: `PhotoStorage` with relative filenames + migration 12 backfill

**Files:**
- Create: `lib/services/photo_storage.dart`
- Modify: `lib/data/local/migrations.dart` (v12), `lib/presentation/screens/medication/add_medication_screen.dart`, `lib/presentation/screens/medication/medication_detail_screen.dart`, `lib/presentation/providers/providers.dart` (`photoStorageProvider`)
- Test: `test/services/photo_storage_test.dart`, extend `test/data/local/app_database_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class PhotoStorage {
    PhotoStorage({required Future<Directory> Function() rootDirectory});   // injectable for tests
    factory PhotoStorage.appDocuments();                                   // path_provider
    static const folder = 'medication_photos';
    Future<String> saveFromPath(String sourcePath);        // copies, returns bare filename 'med_<uuid>.<ext>'
    Future<File?> resolve(String? stored);                 // filename or legacy absolute → existing File or null
    Future<void> delete(String? stored);
    Future<void> deleteAll();
    static String toStoredName(String pathOrName) => p.basename(pathOrName);
  }
  final photoStorageProvider = Provider<PhotoStorage>;
  // migrations.dart: kSchemaVersion = 12; Migration(12, ...) sets image_path = basename(image_path) where it contains '/'
  ```

- [ ] **Step 1: Write the failing tests**

`test/services/photo_storage_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late PhotoStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('medora_photos_');
    storage = PhotoStorage(rootDirectory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test('saveFromPath copies into the photos folder and returns a bare filename', () async {
    final src = File(p.join(root.path, 'src.jpg'))..writeAsBytesSync([1, 2, 3]);
    final name = await storage.saveFromPath(src.path);
    expect(name, isNot(contains('/')));
    expect(name, endsWith('.jpg'));
    final file = (await storage.resolve(name))!;
    expect(file.existsSync(), isTrue);
    expect(p.dirname(file.path), p.join(root.path, PhotoStorage.folder));
  });

  test('resolve accepts a legacy absolute path that still exists', () async {
    final legacy = File(p.join(root.path, 'legacy.png'))..writeAsBytesSync([9]);
    expect((await storage.resolve(legacy.path))!.path, legacy.path);
  });

  test('resolve maps a stale absolute path to the current folder by basename', () async {
    final name = await storage.saveFromPath(
        (File(p.join(root.path, 'x.jpg'))..writeAsBytesSync([1])).path);
    final stale = '/var/mobile/Containers/OLD/Documents/${PhotoStorage.folder}/$name';
    final file = await storage.resolve(stale);
    expect(file, isNotNull);
    expect(p.basename(file!.path), name);
  });

  test('resolve returns null for null, empty and missing', () async {
    expect(await storage.resolve(null), isNull);
    expect(await storage.resolve(''), isNull);
    expect(await storage.resolve('nope.jpg'), isNull);
  });

  test('delete and deleteAll remove files', () async {
    final a = await storage.saveFromPath((File(p.join(root.path, 'a.jpg'))..writeAsBytesSync([1])).path);
    final b = await storage.saveFromPath((File(p.join(root.path, 'b.jpg'))..writeAsBytesSync([1])).path);
    await storage.delete(a);
    expect(await storage.resolve(a), isNull);
    expect(await storage.resolve(b), isNotNull);
    await storage.deleteAll();
    expect(await storage.resolve(b), isNull);
  });
}
```

Append to `test/data/local/app_database_test.dart` (inside `main`, after the existing tests; add `import 'package:medora/data/local/migrations.dart';` if missing — it is already imported):

```dart
  test('migration 12 backfills absolute image_path to a bare filename', () async {
    final dir = await Directory.systemTemp.createTemp('medora_mig12_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: (db, _) async {
          await AppDatabase.createBaseSchema(db);
          await kMigrations.first.run(db); // v11
        },
      ),
    );
    await legacy.insert('medications', {
      'id': 'm1', 'name': 'Old', 'quantity': 1,
      'image_path': '/data/user/0/com.medora.medora/app_flutter/medication_photos/med_abc.jpg',
    });
    await legacy.insert('medications', {'id': 'm2', 'name': 'Bare', 'quantity': 1, 'image_path': 'med_def.jpg'});
    await legacy.insert('medications', {'id': 'm3', 'name': 'None', 'quantity': 1});
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final db = await AppDatabase.instance.database;
    final rows = await db.query('medications', columns: ['id', 'image_path'], orderBy: 'id');
    expect(rows.map((r) => r['image_path']).toList(), ['med_abc.jpg', 'med_def.jpg', null]);
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12]);
    await AppDatabase.instance.reset();
    await dir.delete(recursive: true);
  });
```

Also update the existing test `upgrading a v10 database applies pending migrations exactly once`: its two `expect(await AppDatabase.instance.appliedMigrations(), [11]);` become `[11, 12]`, and the fresh-database test already compares against `kMigrations` so it needs no change.

Run: `fvm flutter test test/services/photo_storage_test.dart test/data/local/app_database_test.dart`
Expected: FAIL — `photo_storage.dart` missing; migration test fails on `[11]` vs `[11, 12]`.

- [ ] **Step 2: Create `lib/services/photo_storage.dart`**

```dart
/// Medora - Medication photo storage.
///
/// Photos are stored under `<app documents>/medication_photos/<filename>` and
/// the database keeps only the filename, so the app container can move
/// (iOS does this on every update) without breaking references.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class PhotoStorage {
  PhotoStorage({required Future<Directory> Function() rootDirectory})
      : _rootDirectory = rootDirectory;

  /// Production storage rooted at the app documents directory.
  factory PhotoStorage.appDocuments() =>
      PhotoStorage(rootDirectory: getApplicationDocumentsDirectory);

  static const folder = 'medication_photos';
  static const _uuid = Uuid();

  final Future<Directory> Function() _rootDirectory;

  Future<Directory> _photosDir() async {
    final dir = Directory(p.join((await _rootDirectory()).path, folder));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The bare filename to persist for any stored value (absolute or bare).
  static String toStoredName(String pathOrName) => p.basename(pathOrName);

  /// Copy [sourcePath] into the photos folder; returns the bare filename.
  Future<String> saveFromPath(String sourcePath) async {
    final dir = await _photosDir();
    final name = 'med_${_uuid.v4()}${p.extension(sourcePath)}';
    await File(sourcePath).copy(p.join(dir.path, name));
    return name;
  }

  /// Resolve a stored value to an existing file.
  /// Accepts a bare filename (current format) or a legacy absolute path:
  /// if the absolute path still exists it is used, otherwise its basename is
  /// looked up in the current photos folder.
  Future<File?> resolve(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    if (p.isAbsolute(stored)) {
      final legacy = File(stored);
      if (legacy.existsSync()) return legacy;
    }
    final file = File(p.join((await _photosDir()).path, toStoredName(stored)));
    return file.existsSync() ? file : null;
  }

  Future<void> delete(String? stored) async {
    final file = await resolve(stored);
    if (file != null && file.existsSync()) await file.delete();
  }

  Future<void> deleteAll() async {
    final dir = await _photosDir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
```

Add to `lib/presentation/providers/providers.dart` (with `import 'package:medora/services/photo_storage.dart';`):

```dart
final photoStorageProvider = Provider<PhotoStorage>((ref) => PhotoStorage.appDocuments());
```

- [ ] **Step 3: Migration 12**

`lib/data/local/migrations.dart`: set `const int kSchemaVersion = 12;` and append to `kMigrations`:

```dart
  // v12: photos are referenced by bare filename (spec §4.3 / audit F10).
  Migration(12, (db) async {
    final rows = await db.query(
      'medications',
      columns: ['id', 'image_path'],
      where: "image_path IS NOT NULL AND image_path LIKE '%/%'",
    );
    for (final row in rows) {
      final path = row['image_path'] as String;
      final name = path.substring(path.lastIndexOf('/') + 1);
      await db.update('medications', {'image_path': name}, where: 'id = ?', whereArgs: [row['id']]);
    }
  }),
```

Update the comment on migration 11 to remove "photo_file arrives with Phase 1" (the spec's `photo_file` column is replaced by reusing `image_path` with bare names — note this in the migration comment).

- [ ] **Step 4: Screens use `PhotoStorage`**

`lib/presentation/screens/medication/add_medication_screen.dart`:
- In `_pickImage`, replace the block from `// Save to app documents directory` through `setState(() => _imagePath = savedPath);` with:
  ```dart
  final name = await ref.read(photoStorageProvider).saveFromPath(picked.path);
  if (!mounted) return;
  setState(() => _imagePath = name);
  ```
  Remove now-unused imports (`path_provider`, `path` as `p`, `Directory`) if the analyzer flags them.
- The preview in `_buildPhotoSection` currently does `File(_imagePath!).existsSync()`. Replace the preview child with a `FutureBuilder<File?>`:
  ```dart
  child: _imagePath == null || kIsWeb
      ? _photoPlaceholder(l10n)
      : FutureBuilder<File?>(
          future: ref.read(photoStorageProvider).resolve(_imagePath),
          builder: (context, snap) {
            final file = snap.data;
            if (file == null) return _photoPlaceholder(l10n);
            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(file, fit: BoxFit.cover, width: double.infinity),
            );
          },
        ),
  ```
  and extract the existing placeholder `Column(...)` (camera icon + `l10n.addPhoto`) into `Widget _photoPlaceholder(AppLocalizations l10n)`.
- When the user taps the delete button for the photo, also call `ref.read(photoStorageProvider).delete(_imagePath)` before `setState(() => _imagePath = null)` (only for names that were saved during this session — to keep it simple, delete only if `!_isEditMode || _imagePath != _existingMedication?.imagePath`).

`lib/presentation/screens/medication/medication_detail_screen.dart`: replace the `if (!kIsWeb && med.imagePath != null && File(med.imagePath!).existsSync()) ...[ ... ]` block with a `FutureBuilder<File?>` on `ref.read(photoStorageProvider).resolve(med.imagePath)` that returns `const SizedBox.shrink()` while loading/null and otherwise the existing `SizedBox(height: 16)` + `GestureDetector(...)` subtree using `file` instead of `File(med.imagePath!)` in both `Image.file` calls. Keep the `!kIsWeb` short-circuit before the `FutureBuilder`.

- [ ] **Step 5: Verify and commit**

Run: `fvm flutter test test/services/photo_storage_test.dart test/data/local/ && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: green / `No issues found!`.

```bash
git add lib/services/photo_storage.dart lib/data/local/migrations.dart lib/presentation test/services/photo_storage_test.dart test/data/local/app_database_test.dart
git commit -m "fix(photos): store medication photos by filename; migrate legacy absolute paths

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 4: `ReminderPort` + `ReminderScheduler` (7-day horizon, 60 cap, toggle respected, stable ids)

**Files:**
- Create: `lib/services/reminder_port.dart`, `lib/services/reminder_scheduler.dart`
- Modify: `lib/services/reminder_service.dart` (implements port; FNV-1a ids; `pendingCount`)
- Modify: `lib/data/datasources/dose_log_local_datasource.dart` (`getPendingBetween`), `lib/domain/repositories/dose_log_repository.dart` + impl (`getPendingDoseLogsBetween`)
- Modify: `lib/presentation/providers/providers.dart` (`reminderPortProvider`, `reminderSchedulerProvider`), `dose_providers.dart` (delegate), `settings_screen.dart` (toggle → reconcile), `treatment_detail_screen.dart` (after prescription save → reconcile instead of direct scheduling)
- Test: `test/services/reminder_scheduler_test.dart`, `test/services/reminder_ids_test.dart`

**Interfaces:**
- Produces:
  ```dart
  // reminder_port.dart
  abstract class ReminderPort {
    Future<void> cancelAll();
    Future<void> scheduleForDose({required DoseLog dose, required String medicationName});  // schedules up to 2 notifications
    int notificationsPerDose = 2 (static const on ReminderScheduler)
  }
  // reminder_service.dart
  class ReminderService implements ReminderPort { static int notificationBaseId(String doseId); /* FNV-1a 32-bit & 0x7FFFFFF0 */ }
  // reminder_scheduler.dart
  class ReminderScheduler {
    ReminderScheduler({required ReminderPort port, required DoseLogRepository doses, required bool Function() remindersEnabled, DateTime Function()? now});
    static const horizon = Duration(days: 7); static const maxNotifications = 60; static const notificationsPerDose = 2;
    Future<int> reconcile();   // returns number of doses scheduled
  }
  // DoseLogRepository
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(DateTime start, DateTime end);
  ```

- [ ] **Step 1: Write the failing tests**

`test/services/reminder_ids_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/reminder_service.dart';

void main() {
  test('notificationBaseId is stable, positive and leaves room for offsets', () {
    const id = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
    final a = ReminderService.notificationBaseId(id);
    final b = ReminderService.notificationBaseId(id);
    expect(a, b);
    expect(a, greaterThan(0));
    expect(a % 16, 0); // low 4 bits reserved for per-dose offsets
    expect(a + 15, lessThanOrEqualTo(0x7FFFFFFF));
  });

  test('different ids map to different bases', () {
    final a = ReminderService.notificationBaseId('dose-a');
    final b = ReminderService.notificationBaseId('dose-b');
    expect(a, isNot(b));
  });
}
```

`test/services/reminder_scheduler_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/reminder_scheduler.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class FakePort implements ReminderPort {
  int cancelAllCalls = 0;
  final scheduled = <DoseLog>[];

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

  @override
  Future<void> scheduleForDose({required DoseLog dose, required String medicationName}) async {
    scheduled.add(dose);
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 3, 1, 9);

  ReminderScheduler make(FakePort port, {bool enabled = true}) => ReminderScheduler(
        port: port,
        doses: DoseLogRepositoryImpl(
          localDatasource: DoseLogLocalDatasource(),
          remoteDatasource: null,
          prescriptionLocal: PrescriptionLocalDatasource(),
        ),
        remindersEnabled: () => enabled,
        now: () => now,
      );

  test('schedules only pending doses inside the 7-day horizon, earliest first', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 1)));            // past → skipped
    final soon = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 2)));
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 3)), status: 'taken'); // not pending
    final later = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(days: 6)));
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(days: 8)));                  // beyond horizon

    final port = FakePort();
    final count = await make(port).reconcile();

    expect(port.cancelAllCalls, 1);
    expect(count, 2);
    expect(port.scheduled.map((d) => d.id).toList(), [soon, later]);
  });

  test('caps at maxNotifications / notificationsPerDose doses', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    for (var i = 1; i <= 40; i++) {
      await seedDoseLog(db, s.prescriptionId, now.add(Duration(hours: i)));
    }
    final port = FakePort();
    final count = await make(port).reconcile();
    expect(count, ReminderScheduler.maxNotifications ~/ ReminderScheduler.notificationsPerDose);
    expect(port.scheduled.length, 30);
    expect(port.scheduled.first.scheduledTime, now.add(const Duration(hours: 1)));
  });

  test('when reminders are disabled it cancels and schedules nothing', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = FakePort();
    final count = await make(port, enabled: false).reconcile();
    expect(port.cancelAllCalls, 1);
    expect(count, 0);
    expect(port.scheduled, isEmpty);
  });
}
```

Run: `fvm flutter test test/services/reminder_ids_test.dart test/services/reminder_scheduler_test.dart`
Expected: FAIL — files/classes missing.

- [ ] **Step 2: Create `lib/services/reminder_port.dart`**

```dart
/// Medora - Notification port.
///
/// The scheduler talks to this interface; [ReminderService] implements it
/// with flutter_local_notifications, tests use a fake.
library;

import 'package:medora/domain/entities/dose_log.dart';

abstract class ReminderPort {
  /// Cancel every pending notification owned by the app.
  Future<void> cancelAll();

  /// Schedule the notifications for one dose (currently two: 60 min before
  /// and at the scheduled time). Past times are skipped.
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  });
}
```

- [ ] **Step 3: Datasource + repository query for pending doses in a range**

`lib/data/datasources/dose_log_local_datasource.dart`, after `getDoseLogsByDateRange`:

```dart
  /// Pending doses with scheduled_time in [start, end), for active
  /// prescriptions/treatments and non-archived medications, earliest first.
  Future<List<DoseLogModel>> getPendingBetween(DateTime start, DateTime end) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''$_activeJoinQuery
        WHERE d.status = 'pending'
        AND d.scheduled_time >= ? AND d.scheduled_time < ?
        AND d.sync_status != ?
        AND (p.is_active IS NULL OR p.is_active = 1)
        AND (t.id IS NULL OR t.is_active = 1)
        AND (m.id IS NULL OR (m.is_archived IS NULL OR m.is_archived = 0))
        ORDER BY d.scheduled_time ASC''',
      [start.toIso8601String(), end.toIso8601String(), SyncStatus.pendingDelete],
    );
    return rows.map(_fromRow).toList();
  }
```

`lib/domain/repositories/dose_log_repository.dart`: add

```dart
  /// Pending doses scheduled in [start, end), earliest first.
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(DateTime start, DateTime end);
```

Impl:

```dart
  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(DateTime start, DateTime end) async {
    try {
      final models = await localDatasource.getPendingBetween(start, end);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load pending doses: $e', st);
    }
  }
```

- [ ] **Step 4: Create `lib/services/reminder_scheduler.dart`**

```dart
/// Medora - Reminder scheduler.
///
/// Single owner of "which notifications exist". [reconcile] cancels
/// everything and re-schedules pending doses for the next [horizon],
/// earliest first, capped at [maxNotifications]. When reminders are
/// disabled it only cancels.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/reminder_port.dart';

class ReminderScheduler {
  ReminderScheduler({
    required ReminderPort port,
    required DoseLogRepository doses,
    required bool Function() remindersEnabled,
    DateTime Function()? now,
  })  : _port = port,
        _doses = doses,
        _remindersEnabled = remindersEnabled,
        _now = now ?? DateTime.now;

  static const horizon = Duration(days: 7);
  static const maxNotifications = 60; // iOS allows 64 pending
  static const notificationsPerDose = 2;

  final ReminderPort _port;
  final DoseLogRepository _doses;
  final bool Function() _remindersEnabled;
  final DateTime Function() _now;

  bool _running = false;

  /// Returns the number of doses that received notifications.
  Future<int> reconcile() async {
    if (_running) return 0;
    _running = true;
    try {
      await _port.cancelAll();
      if (!_remindersEnabled()) return 0;

      final now = _now();
      final result = await _doses.getPendingDoseLogsBetween(now, now.add(horizon));
      final pending = result.dataOrNull ?? [];
      final limit = maxNotifications ~/ notificationsPerDose;

      var scheduled = 0;
      for (final dose in pending) {
        if (scheduled >= limit) break;
        await _port.scheduleForDose(
          dose: dose,
          medicationName: dose.medicationName ?? 'Medication',
        );
        scheduled++;
      }
      debugPrint('Reminders: scheduled $scheduled of ${pending.length} pending doses');
      return scheduled;
    } finally {
      _running = false;
    }
  }
}
```

- [ ] **Step 5: `ReminderService` implements the port with stable ids**

In `lib/services/reminder_service.dart`:
- `class ReminderService implements ReminderPort` (import `package:medora/services/reminder_port.dart`).
- Add:
  ```dart
  /// Stable 31-bit notification id base for a dose (FNV-1a over the id,
  /// low 4 bits cleared so per-dose offsets never collide).
  static int notificationBaseId(String doseId) {
    var hash = 0x811C9DC5;
    for (final unit in doseId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFF0;
  }
  ```
- Replace both `dose.id.hashCode` / `doseId.hashCode` with `notificationBaseId(...)`.
- Add the port methods:
  ```dart
  @override
  Future<void> cancelAll() => cancelAllReminders();

  @override
  Future<void> scheduleForDose({required DoseLog dose, required String medicationName}) =>
      scheduleRemindersForDose(dose: dose, medicationName: medicationName, cancelFirst: false);
  ```
  (`cancelFirst: false` because `reconcile` already cancelled everything.)

- [ ] **Step 6: Wire providers and replace ad-hoc scheduling**

`lib/presentation/providers/providers.dart` (imports for `reminder_port.dart`, `reminder_scheduler.dart`, `settings_providers.dart`):

```dart
final reminderPortProvider = Provider<ReminderPort>((ref) => ReminderService.instance);

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  return ReminderScheduler(
    port: ref.watch(reminderPortProvider),
    doses: ref.watch(doseLogRepositoryProvider),
    remindersEnabled: () => ref.read(remindersEnabledProvider),
  );
});
```

`lib/presentation/providers/dose_providers.dart`:
- Delete `_scheduleUpcomingReminders` and every call to it, and every direct `ReminderService.instance.*` call in `markTaken`, `undoTaken`, `markSkipped`, `markMissed`. Remove the now-unused `reminder_service.dart` and `kIsWeb` imports.
- In `_refreshAndInvalidateHistory()` and `refresh()` add, after the state update: `unawaited(ref.read(reminderSchedulerProvider).reconcile());` (import `dart:async`).
- In `build()`, after `final doses = await _fetchTodaysDoses();` add `unawaited(ref.read(reminderSchedulerProvider).reconcile());`.
- Remove the `static bool _startupCheckDone` flag: keep `_ensureDoseLogsExistInBackground()` but call it unconditionally from `build()` (it is idempotent — it only generates missing logs), and drop the `if (_startupCheckDone)` guard inside it (just set state after generation).

`lib/presentation/screens/settings/settings_screen.dart`, reminders `SwitchListTile.onChanged`: replace the body with

```dart
              if (value) await ReminderService.instance.requestPermissions();
              await ref.read(remindersEnabledProvider.notifier).set(value);
              await ref.read(reminderSchedulerProvider).reconcile();
```

(`reconcile` cancels when disabled; no more `ref.invalidate(todaysDoseLogsProvider)` here.) The "Cancel all reminders" tile stays as is.

`lib/presentation/screens/treatment/treatment_detail_screen.dart`: in the add-prescription success branch, delete the `// Schedule reminders (non-blocking)` try-block that loops `ReminderService.instance.scheduleRemindersForDose(...)`; after `ref.invalidate(todaysDoseLogsProvider);` at the end of the save handler add `unawaited(ref.read(reminderSchedulerProvider).reconcile());` (import `dart:async`). Remove the unused `reminder_service.dart` import if the analyzer flags it. The `regenerateDoseLogsForPrescription` path in `dose_log_repository_impl.dart` still calls `ReminderService.instance.cancelRemindersForDose(...)` per pending log — replace that loop with nothing (reconcile after save covers it) and remove the import there too.

- [ ] **Step 7: Verify and commit**

Run: `fvm flutter test test/services/ test/data/ && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: green / `No issues found!`. Confirm `grep -rn "ReminderService.instance.schedule\|_scheduleUpcomingReminders\|hashCode" lib/presentation lib/services lib/data` returns nothing.

```bash
git add lib test
git commit -m "feat(reminders): ReminderScheduler with 7-day horizon, 60-notification cap and toggle

Scheduling is owned by one reconcile() behind a ReminderPort interface;
notification ids are FNV-1a based and stable across runs. The Settings
toggle now really disables reminders.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---
### Task 5: `DoseMaintenanceService` (overdue → missed), grace setting, `AppStartupTasks` on start/resume

**Files:**
- Create: `lib/services/dose_maintenance_service.dart`, `lib/services/app_startup_tasks.dart`
- Modify: `lib/data/datasources/dose_log_local_datasource.dart` (`markOverduePendingAsMissed`), `lib/domain/repositories/dose_log_repository.dart` + impl
- Modify: `lib/presentation/providers/settings_providers.dart` (`missedGraceMinutesProvider`), `providers.dart` (`doseMaintenanceProvider`, `appStartupTasksProvider`, `syncStartupDelayProvider`)
- Modify: `lib/presentation/screens/main_shell_screen.dart` (lifecycle → startup tasks; remove hardcoded 2s timer)
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (grace picker tile)
- Modify: ARB en/de/it (+ gen-l10n)
- Test: `test/services/dose_maintenance_service_test.dart`, `test/services/app_startup_tasks_test.dart`; update `test/presentation/router/app_router_widget_test.dart` (override `syncStartupDelayProvider` with `Duration.zero`, drop the 3-second pumps)

**Interfaces:**
- Produces:
  ```dart
  // DoseLogLocalDatasource / DoseLogRepository
  Future<int> markOverduePendingAsMissed(DateTime cutoff);            // rows updated
  // dose_maintenance_service.dart
  class DoseMaintenanceService { DoseMaintenanceService({required DoseLogRepository doses, DateTime Function()? now});
    Future<int> markOverdueAsMissed({required Duration grace}); }
  // app_startup_tasks.dart
  class AppStartupTasks { AppStartupTasks({required Future<void> Function() maintenance, required Future<void> Function() reminders, required Future<void> Function() sync, required Duration syncDelay});
    Future<void> run({bool includeSync = true}); }                     // maintenance → reminders → (delayed) sync
  // settings_providers.dart
  final missedGraceMinutesProvider = NotifierProvider<MissedGraceMinutesNotifier, int>;   // default 120; .set(int)
  const kMissedGraceOptions = [30, 60, 120, 240];
  // providers.dart
  final doseMaintenanceProvider = Provider<DoseMaintenanceService>;
  final syncStartupDelayProvider = Provider<Duration>((_) => const Duration(seconds: 2));
  final appStartupTasksProvider = Provider<AppStartupTasks>;
  ```

- [ ] **Step 1: ARB keys**

Add to `app_en.arb`:
```json
  "missedGracePeriod": "Mark as missed after",
  "missedGracePeriodDesc": "Pending doses older than this are marked missed when the app opens",
  "minutesShort": "{minutes} min",
  "@minutesShort": { "placeholders": { "minutes": { "type": "int" } } },
  "hoursShort": "{hours} h",
  "@hoursShort": { "placeholders": { "hours": { "type": "int" } } }
```
`app_de.arb`:
```json
  "missedGracePeriod": "Als verpasst markieren nach",
  "missedGracePeriodDesc": "Ausstehende Dosen, die älter sind, werden beim Öffnen der App als verpasst markiert",
  "minutesShort": "{minutes} Min.",
  "@minutesShort": { "placeholders": { "minutes": { "type": "int" } } },
  "hoursShort": "{hours} Std.",
  "@hoursShort": { "placeholders": { "hours": { "type": "int" } } }
```
`app_it.arb`:
```json
  "missedGracePeriod": "Segna come saltata dopo",
  "missedGracePeriodDesc": "Le dosi in sospeso più vecchie vengono segnate come saltate all'apertura dell'app",
  "minutesShort": "{minutes} min",
  "@minutesShort": { "placeholders": { "minutes": { "type": "int" } } },
  "hoursShort": "{hours} h",
  "@hoursShort": { "placeholders": { "hours": { "type": "int" } } }
```
Run `fvm flutter gen-l10n`; `untranslated.txt` must be `{}`.

- [ ] **Step 2: Write the failing tests**

`test/services/dose_maintenance_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/dose_maintenance_service.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 3, 1, 12);

  test('marks pending doses older than the grace period as missed, leaves the rest', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final old = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 3)));
    final recent = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(minutes: 30)));
    final future = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final taken = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 5)), status: 'taken');

    final repo = DoseLogRepositoryImpl(
      localDatasource: DoseLogLocalDatasource(),
      remoteDatasource: null,
      prescriptionLocal: PrescriptionLocalDatasource(),
    );
    final service = DoseMaintenanceService(doses: repo, now: () => now);
    final changed = await service.markOverdueAsMissed(grace: const Duration(minutes: 120));

    expect(changed, 1);
    final ds = DoseLogLocalDatasource();
    expect((await ds.getDoseLogById(old))!.status, DoseStatus.missed);
    expect((await ds.getDoseLogById(recent))!.status, DoseStatus.pending);
    expect((await ds.getDoseLogById(future))!.status, DoseStatus.pending);
    expect((await ds.getDoseLogById(taken))!.status, DoseStatus.taken);
    // Marked rows are flagged for sync and stamped.
    final row = (await db.query('dose_logs', where: 'id = ?', whereArgs: [old])).first;
    expect(row['sync_status'], SyncStatus.pendingUpdate);
    expect(row['updated_at'], isNotNull);
  });
}
```

`test/services/app_startup_tasks_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/app_startup_tasks.dart';

void main() {
  test('runs maintenance, then reminders, then sync after the delay', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('maintenance'),
      reminders: () async => calls.add('reminders'),
      sync: () async => calls.add('sync'),
      syncDelay: Duration.zero,
    );
    await tasks.run();
    expect(calls, ['maintenance', 'reminders', 'sync']);
  });

  test('includeSync=false skips sync', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => calls.add('m'),
      reminders: () async => calls.add('r'),
      sync: () async => calls.add('s'),
      syncDelay: Duration.zero,
    );
    await tasks.run(includeSync: false);
    expect(calls, ['m', 'r']);
  });

  test('a failing step does not stop the others', () async {
    final calls = <String>[];
    final tasks = AppStartupTasks(
      maintenance: () async => throw StateError('boom'),
      reminders: () async => calls.add('r'),
      sync: () async => calls.add('s'),
      syncDelay: Duration.zero,
    );
    await tasks.run();
    expect(calls, ['r', 's']);
  });

  test('concurrent runs are coalesced', () async {
    var maintenanceRuns = 0;
    final tasks = AppStartupTasks(
      maintenance: () async { maintenanceRuns++; await Future<void>.delayed(const Duration(milliseconds: 20)); },
      reminders: () async {},
      sync: () async {},
      syncDelay: Duration.zero,
    );
    await Future.wait([tasks.run(), tasks.run()]);
    expect(maintenanceRuns, 1);
  });
}
```

Run both: expected FAIL — classes missing.

- [ ] **Step 3: Datasource + repository**

`dose_log_local_datasource.dart`:

```dart
  /// Mark pending doses scheduled before [cutoff] as missed. Returns the count.
  Future<int> markOverduePendingAsMissed(DateTime cutoff) async {
    final db = await _db;
    return db.update(
      'dose_logs',
      {
        'status': 'missed',
        'sync_status': SyncStatus.pendingUpdate,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: "status = 'pending' AND scheduled_time < ? AND sync_status != ?",
      whereArgs: [cutoff.toIso8601String(), SyncStatus.pendingDelete],
    );
  }
```

Interface + impl:

```dart
  /// Mark pending doses scheduled before [cutoff] as missed; returns the count.
  Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff);
```
```dart
  @override
  Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff) async {
    try {
      return Result.success(await localDatasource.markOverduePendingAsMissed(cutoff));
    } catch (e, st) {
      return Result.failure('Failed to mark overdue doses: $e', st);
    }
  }
```

Note: rows changed this way are not pushed individually; `SyncService._pushPendingChanges` picks them up on the next sync because they are `pending_update`.

- [ ] **Step 4: Services**

`lib/services/dose_maintenance_service.dart`:

```dart
/// Medora - Dose maintenance.
///
/// Turns stale pending doses into "missed" so history and stats are honest.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';

class DoseMaintenanceService {
  DoseMaintenanceService({required DoseLogRepository doses, DateTime Function()? now})
      : _doses = doses,
        _now = now ?? DateTime.now;

  final DoseLogRepository _doses;
  final DateTime Function() _now;

  /// Marks pending doses older than [grace] as missed. Returns the count.
  Future<int> markOverdueAsMissed({required Duration grace}) async {
    final cutoff = _now().subtract(grace);
    final result = await _doses.markOverduePendingAsMissed(cutoff);
    final count = result.dataOrNull ?? 0;
    if (count > 0) debugPrint('Doses: marked $count overdue dose(s) as missed');
    return count;
  }
}
```

`lib/services/app_startup_tasks.dart`:

```dart
/// Medora - Work that runs on app start and on foreground resume.
///
/// Order matters: maintenance changes dose statuses, reminders are then
/// reconciled from the corrected data, and sync (cloud mode) runs last after
/// a short delay so the first frame is not competing with network work.
library;

import 'package:flutter/foundation.dart';

class AppStartupTasks {
  AppStartupTasks({
    required Future<void> Function() maintenance,
    required Future<void> Function() reminders,
    required Future<void> Function() sync,
    required Duration syncDelay,
  })  : _maintenance = maintenance,
        _reminders = reminders,
        _sync = sync,
        _syncDelay = syncDelay;

  final Future<void> Function() _maintenance;
  final Future<void> Function() _reminders;
  final Future<void> Function() _sync;
  final Duration _syncDelay;

  Future<void>? _inFlight;

  Future<void> run({bool includeSync = true}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _runOnce(includeSync).whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _runOnce(bool includeSync) async {
    await _guard('maintenance', _maintenance);
    await _guard('reminders', _reminders);
    if (includeSync) {
      if (_syncDelay > Duration.zero) await Future<void>.delayed(_syncDelay);
      await _guard('sync', _sync);
    }
  }

  Future<void> _guard(String name, Future<void> Function() step) async {
    try {
      await step();
    } catch (e, st) {
      debugPrint('Startup task "$name" failed: $e\n$st');
    }
  }
}
```

- [ ] **Step 5: Settings provider + DI**

`settings_providers.dart` (after the Reminders setting):

```dart
// ── Missed-dose grace period ─────────────────────────────────
const _kMissedGraceMinutes = 'missed_grace_minutes';
const kMissedGraceOptions = [30, 60, 120, 240];

final missedGraceMinutesProvider =
    NotifierProvider<MissedGraceMinutesNotifier, int>(MissedGraceMinutesNotifier.new);

class MissedGraceMinutesNotifier extends Notifier<int> {
  @override
  int build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getInt(_kMissedGraceMinutes) ?? 120;
  }

  Future<void> set(int minutes) async {
    state = minutes;
    await ref.read(sharedPreferencesProvider).setInt(_kMissedGraceMinutes, minutes);
  }
}
```

`providers.dart` (imports for the two services, `dose_providers.dart`, `app_mode_provider.dart`):

```dart
final doseMaintenanceProvider = Provider<DoseMaintenanceService>(
  (ref) => DoseMaintenanceService(doses: ref.watch(doseLogRepositoryProvider)),
);

/// Delay before the startup sync; tests override this with Duration.zero.
final syncStartupDelayProvider = Provider<Duration>((_) => const Duration(seconds: 2));

final appStartupTasksProvider = Provider<AppStartupTasks>((ref) {
  return AppStartupTasks(
    maintenance: () async {
      final grace = Duration(minutes: ref.read(missedGraceMinutesProvider));
      final changed = await ref.read(doseMaintenanceProvider).markOverdueAsMissed(grace: grace);
      if (changed > 0) {
        await ref.read(todaysDoseLogsProvider.notifier).refresh();
        ref.read(doseDataVersionProvider.notifier).bump();
      }
    },
    reminders: () => ref.read(reminderSchedulerProvider).reconcile().then((_) {}),
    sync: () async {
      if (ref.read(appModeProvider) == AppMode.cloud) {
        await ref.read(syncServiceProvider).syncAll();
      }
    },
    syncDelay: ref.watch(syncStartupDelayProvider),
  );
});
```

- [ ] **Step 6: `MainShellScreen` lifecycle hook**

Replace the `initState` body and add an observer:

```dart
class _MainShellScreenState extends ConsumerState<MainShellScreen> with WidgetsBindingObserver {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(appStartupTasksProvider).run());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(ref.read(appStartupTasksProvider).run());
    }
  }
```

(import `dart:async`). The rest of the widget is unchanged.

- [ ] **Step 7: Settings tile**

In `settings_screen.dart`, under the Notifications section after the "Cancel all reminders" tile, add (watch `final graceMinutes = ref.watch(missedGraceMinutesProvider);` at the top of `build`):

```dart
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: Text(l10n.missedGracePeriod),
            subtitle: Text(l10n.missedGracePeriodDesc),
            trailing: DropdownButton<int>(
              value: graceMinutes,
              underline: const SizedBox.shrink(),
              items: [
                for (final m in kMissedGraceOptions)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m < 60 ? l10n.minutesShort(m) : l10n.hoursShort(m ~/ 60)),
                  ),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await ref.read(missedGraceMinutesProvider.notifier).set(v);
                await ref.read(appStartupTasksProvider).run(includeSync: false);
              },
            ),
          ),
```

- [ ] **Step 8: Update the router widget test**

In `test/presentation/router/app_router_widget_test.dart` add `syncStartupDelayProvider.overrideWithValue(Duration.zero)` to the container overrides (import `providers.dart`) and delete the trailing `await tester.pump(const Duration(seconds: 3));` lines and their comments. Run that file to confirm it still passes.

- [ ] **Step 9: Verify and commit**

Run: `fvm flutter gen-l10n && cat untranslated.txt && fvm flutter test test/services/ test/presentation/router/ && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: `{}`, green, `No issues found!`.

```bash
git add lib test
git commit -m "feat(doses): mark overdue doses missed with a configurable grace; startup/resume tasks

DoseMaintenanceService + AppStartupTasks run maintenance, reminder
reconcile and (cloud) sync on app start and resume; the 2s sync timer is
now an injectable provider.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 6: No loading flash on list mutations; `expiringSoon` excludes expired

**Files:**
- Modify: `lib/presentation/providers/medication_providers.dart`, `treatment_providers.dart`
- Modify: `lib/presentation/screens/medication/medication_list_screen.dart` (`needsAttention` filter includes expiring-soon)
- Test: `test/presentation/providers/medication_providers_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<ProviderContainer> make() async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    return c;
  }

  test('expiringSoonProvider lists only unexpired items within 30 days', () async {
    final c = await make();
    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);
    final today = DateTime.now();
    await notifier.addMedication(Medication(id: 'a', name: 'Expired', quantity: 1, expiryDate: today.subtract(const Duration(days: 1))));
    await notifier.addMedication(Medication(id: 'b', name: 'Soon', quantity: 1, expiryDate: today.add(const Duration(days: 10))));
    await notifier.addMedication(Medication(id: 'c', name: 'Far', quantity: 1, expiryDate: today.add(const Duration(days: 90))));

    final soon = await c.read(expiringSoonProvider.future);
    expect(soon.map((m) => m.name).toList(), ['Soon']);
  });

  test('mutations do not pass through a loading state', () async {
    final c = await make();
    await c.read(medicationListProvider.future);
    final states = <AsyncValue<List<Medication>>>[];
    c.listen(medicationListProvider, (_, next) => states.add(next), fireImmediately: false);

    await c.read(medicationListProvider.notifier).addMedication(const Medication(id: 'x', name: 'X', quantity: 1));
    await c.read(medicationListProvider.notifier).updateQuantity('x', 2);

    expect(states.any((s) => s.isLoading && !s.hasValue), isFalse, reason: 'list flashed a spinner');
    expect(states.last.value!.single.quantity, 3);
  });
}
```

Run: `fvm flutter test test/presentation/providers/medication_providers_test.dart`
Expected: FAIL — first test returns `['Expired', 'Soon']`; second sees a loading state.

- [ ] **Step 2: Providers**

`medication_providers.dart`:
- `refresh()`: delete `state = const AsyncLoading();` (keep `state = await AsyncValue.guard(_fetchMedications);`).
- `expiringSoonProvider`: replace the filter with `meds.where((m) => !m.isArchived && m.isExpiringSoon(days: 30) && !m.isExpired).toList()`.

`treatment_providers.dart` `refresh()`: delete `state = const AsyncLoading();`.

`medication_list_screen.dart` `_applyFilter` `needsAttention`: replace `return isLowStock || isExpired;` with `return isLowStock || isExpired || m.isExpiringSoon();` so the chip label "Low stock / Expired" also catches expiring-soon items (and rename the chip label to `'${l10n.lowStock} · ${l10n.expiringSoon}'`).

- [ ] **Step 3: Verify and commit**

Run: `fvm flutter test test/presentation/providers/ && fvm flutter analyze --fatal-infos && fvm flutter test`

```bash
git add lib/presentation test/presentation/providers/medication_providers_test.dart
git commit -m "fix(lists): keep data during refresh; expiring-soon excludes expired

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 7: Delete-all cleans reminders and photos; cloud turn-off offers keep / wipe

**Files:**
- Create: `lib/services/local_data_wiper.dart`
- Modify: `lib/presentation/providers/providers.dart` (`localDataWiperProvider`), `settings_screen.dart` (delete-all + turn-off dialog)
- Modify: ARB en/de/it (+ gen-l10n)
- Test: `test/services/local_data_wiper_test.dart`

**Interfaces:**
```dart
class LocalDataWiper {
  LocalDataWiper({required AppDatabase database, required PhotoStorage photos, required ReminderPort reminders, required SharedPreferences prefs});
  Future<void> wipe();   // cancel reminders → delete photos → clearAllData → remove per-user prefs (aifa_last_sync, aifa_count are kept)
}
final localDataWiperProvider = Provider<LocalDataWiper>;
```

- [ ] **Step 1: ARB keys**

en:
```json
  "keepLocalData": "Keep my data on this device",
  "wipeLocalData": "Delete my data from this device",
  "turnOffCloudSyncChoice": "You will be signed out. What should happen to the data stored on this device?"
```
de:
```json
  "keepLocalData": "Meine Daten auf diesem Gerät behalten",
  "wipeLocalData": "Meine Daten von diesem Gerät löschen",
  "turnOffCloudSyncChoice": "Du wirst abgemeldet. Was soll mit den auf diesem Gerät gespeicherten Daten passieren?"
```
it:
```json
  "keepLocalData": "Mantieni i miei dati su questo dispositivo",
  "wipeLocalData": "Elimina i miei dati da questo dispositivo",
  "turnOffCloudSyncChoice": "Verrai disconnesso. Cosa fare con i dati salvati su questo dispositivo?"
```
Run `fvm flutter gen-l10n`.

- [ ] **Step 2: Write the failing test**

`test/services/local_data_wiper_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/local_data_wiper.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class _Port implements ReminderPort {
  int cancels = 0;
  @override
  Future<void> cancelAll() async => cancels++;
  @override
  Future<void> scheduleForDose({required DoseLog dose, required String medicationName}) async {}
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('wipe cancels reminders, deletes photos and rows, keeps AIFA prefs', () async {
    final root = await Directory.systemTemp.createTemp('medora_wipe_');
    addTearDown(() => root.delete(recursive: true));
    final photos = PhotoStorage(rootDirectory: () async => root);
    final name = await photos.saveFromPath((File(p.join(root.path, 'a.jpg'))..writeAsBytesSync([1])).path);

    SharedPreferences.setMockInitialValues({'aifa_count': 5, 'app_mode': 'cloud', 'theme_mode': 'dark'});
    final prefs = await SharedPreferences.getInstance();

    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, DateTime(2026, 3, 1, 8));

    final port = _Port();
    await LocalDataWiper(database: AppDatabase.instance, photos: photos, reminders: port, prefs: prefs).wipe();

    expect(port.cancels, 1);
    expect(await photos.resolve(name), isNull);
    for (final t in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      expect(await db.query(t), isEmpty, reason: t);
    }
    expect(prefs.getInt('aifa_count'), 5);
    expect(prefs.getString('theme_mode'), 'dark');
  });
}
```

Run: expected FAIL — class missing.

- [ ] **Step 3: Create `lib/services/local_data_wiper.dart`**

```dart
/// Medora - Wipes everything the user created on this device.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalDataWiper {
  LocalDataWiper({
    required AppDatabase database,
    required PhotoStorage photos,
    required ReminderPort reminders,
    required SharedPreferences prefs,
  })  : _database = database,
        _photos = photos,
        _reminders = reminders,
        _prefs = prefs;

  final AppDatabase _database;
  final PhotoStorage _photos;
  final ReminderPort _reminders;
  final SharedPreferences _prefs;

  /// Removes user data: notifications, photos, database rows.
  /// App preferences (theme, language, AIFA cache metadata) are kept.
  Future<void> wipe() async {
    await _reminders.cancelAll();
    await _photos.deleteAll();
    await _database.clearAllData();
    // No per-user prefs exist yet; keep this hook for future keys.
    await _prefs.reload();
  }
}
```

`providers.dart`:

```dart
final localDataWiperProvider = Provider<LocalDataWiper>((ref) => LocalDataWiper(
      database: AppDatabase.instance,
      photos: ref.watch(photoStorageProvider),
      reminders: ref.watch(reminderPortProvider),
      prefs: ref.watch(sharedPreferencesProvider),
    ));
```

- [ ] **Step 4: Settings**

`_showDeleteAllDialog`: replace `await AppDatabase.instance.clearAllData();` with `await ref.read(localDataWiperProvider).wipe();` and remove the now-unused `app_database.dart` import if flagged.

`_confirmTurnOffCloud`: replace the dialog with a three-way choice:

```dart
  Future<void> _confirmTurnOffCloud(BuildContext context, WidgetRef ref, AppLocalizations l10n) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.turnOffCloudSync),
        content: Text(l10n.turnOffCloudSyncChoice),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'wipe'),
            child: Text(l10n.wipeLocalData, style: const TextStyle(color: Colors.red)),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'keep'), child: Text(l10n.keepLocalData)),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(appModeProvider.notifier).set(AppMode.localOnly);
    await ref.read(authControllerProvider.notifier).signOut();
    if (choice == 'wipe') {
      await ref.read(localDataWiperProvider).wipe();
      ref.invalidate(medicationListProvider);
      ref.invalidate(treatmentListProvider);
      ref.invalidate(todaysDoseLogsProvider);
      ref.invalidate(activePrescriptionsProvider);
    }
  }
```

- [ ] **Step 5: Verify and commit**

Run: `fvm flutter gen-l10n && cat untranslated.txt && fvm flutter test test/services/ && fvm flutter analyze --fatal-infos && fvm flutter test`

```bash
git add lib test
git commit -m "feat(settings): delete-all wipes reminders and photos; cloud turn-off offers keep or wipe

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

## Phase 1 exit criteria

- [ ] Undo on a taken dose shows it pending with no "taken at" time; history reflects it.
- [ ] A pending dose older than the grace period becomes "missed" on app start/resume; Settings lets the user pick 30 min / 1 h / 2 h / 4 h.
- [ ] Reminders exist for pending doses up to 7 days ahead (≤ 60 notifications); turning the toggle off removes them and keeps them off after any dose change.
- [ ] Quantity taps, archive, delete do not flash a spinner on the list.
- [ ] Home "Expiring soon" never shows already-expired items.
- [ ] A pulled row keeps the remote `updated_at`; a local edit bumps it.
- [ ] Medication photos survive an app-container move (stored by filename; v11 rows migrated).
- [ ] Delete-all leaves no notifications or photo files; turning cloud sync off offers keep/wipe.
- [ ] `fvm flutter analyze --fatal-infos` clean, `fvm flutter test` green, CI green.
