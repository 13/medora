import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../helpers/failing_dose_repo.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Exposes the provider-side [DoseDataRefresh.invalidateDoseData] extension
/// to the test, exactly as a screen's `ref` would call it.
final invalidateDoseDataProvider = Provider<void Function()>(
  (ref) => ref.invalidateDoseData,
);

void main() {
  late ProviderContainer c;
  final now = DateTime.now();
  // `today`/`tomorrow` are day *selectors* only (for dosesForDayProvider's
  // date-range argument, which normalizes via dayKey regardless of
  // time-of-day) — noon keeps them safely on the correct calendar day.
  // getTodaysDoseLogs/DoseMaintenanceService key off the real wall clock
  // (by design — see their docs), not nowProvider, so the actual dose-log
  // seed *times* below use `recentToday`/`laterToday`, which clamp
  // relative to the REAL now to stay on today's calendar day and inside
  // the missed-dose grace window no matter what hour the suite runs at.
  final today = DateTime(now.year, now.month, now.day, 12);
  final tomorrow = today.add(const Duration(days: 1));

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        nowProvider.overrideWithValue(() => now),
      ],
    );
  });
  tearDown(() async {
    c.dispose();
    await tearDownTestDatabase();
  });

  test(
    'dosesForDayProvider returns only that day and refreshes on version bump',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final a = await seedDoseLog(db, s.prescriptionId, laterToday(now));
      await seedDoseLog(
        db,
        s.prescriptionId,
        tomorrow.add(const Duration(hours: 8)),
      );

      expect(
        (await c.read(dosesForDayProvider(today).future)).map((d) => d.id),
        [a],
      );
      expect((await c.read(dosesForDayProvider(tomorrow).future)).length, 1);

      await c.read(doseActionsProvider).take(a);
      final after = await c.read(dosesForDayProvider(today).future);
      expect(after.single.status, DoseStatus.taken);
    },
  );

  test('dayKey normalizes to midnight', () {
    expect(dayKey(DateTime(2026, 3, 5, 17, 42)), DateTime(2026, 3, 5));
  });

  test(
    'nextDueDoseProvider picks the earliest pending within 2h, else the earliest pending',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final soon = await seedDoseLog(
        db,
        s.prescriptionId,
        laterToday(now, minutes: 30),
      );
      await seedDoseLog(
        db,
        s.prescriptionId,
        recentToday(now, minutes: 300),
        status: 'taken',
      );
      await c.read(todaysDoseLogsProvider.future);
      expect(c.read(nextDueDoseProvider)?.id, soon);

      await c.read(doseActionsProvider).take(soon);
      await c.read(todaysDoseLogsProvider.future);
      expect(c.read(nextDueDoseProvider), isNull);
    },
  );

  test('takeAllDue marks each id taken and returns the taken ids', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(now, minutes: 120),
    );
    final b = await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(now, minutes: 60),
    );
    final taken = await c.read(doseActionsProvider).takeAllDue([a, b]);
    expect(taken.length, 2);
    expect(taken, containsAll([a, b]));
    final doses = await c.read(dosesForDayProvider(today).future);
    expect(doses.where((d) => d.status == DoseStatus.taken).length, 2);
  });

  test(
    'taking a scheduled "400 mg" dose takes one tablet from stock',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await db.update(
        'prescriptions',
        {'auto_diminish': 1, 'dosage': '400 mg', 'dosage_amount': null},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      await db.update(
        'medications',
        {'quantity': 20},
        where: 'id = ?',
        whereArgs: [s.medicationId],
      );
      final id = await seedDoseLog(db, s.prescriptionId, recentToday(now));

      await c.read(doseActionsProvider).take(id);
      Future<int?> stock() async =>
          (await db.query(
                'medications',
                where: 'id = ?',
                whereArgs: [s.medicationId],
              )).single['quantity']
              as int?;
      expect(await stock(), 19);

      await c.read(doseActionsProvider).undoTake(id);
      expect(await stock(), 20);
    },
  );

  test(
    'takeAllDue skips ids that are not pending and does not double-count or double-diminish them',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final a = await seedDoseLog(
        db,
        s.prescriptionId,
        recentToday(now, minutes: 120),
      );
      final b = await seedDoseLog(
        db,
        s.prescriptionId,
        recentToday(now, minutes: 60),
      );
      final alreadyTaken = await seedDoseLog(
        db,
        s.prescriptionId,
        recentToday(now, minutes: 180),
        status: 'taken',
      );

      final taken = await c.read(doseActionsProvider).takeAllDue([
        a,
        b,
        alreadyTaken,
      ]);
      expect(taken.length, 2);
      expect(taken, isNot(contains(alreadyTaken)));

      final med = await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [s.medicationId],
      );
      expect(med.single['quantity'], 8);
    },
  );

  test('take returns false for an unknown id', () async {
    final result = await c.read(doseActionsProvider).take('does-not-exist');
    expect(result, isFalse);
  });

  test(
    'dosesForDayProvider hides pending doses of inactive prescriptions but keeps taken ones',
    () async {
      final db = await AppDatabase.instance.database;
      await seedPrescription(db);
      final s2 = await seedPrescription(db);
      await db.update(
        'prescriptions',
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: [s2.prescriptionId],
      );
      final pending = await seedDoseLog(db, s2.prescriptionId, laterToday(now));
      final taken = await seedDoseLog(
        db,
        s2.prescriptionId,
        laterToday(now, minutes: 90),
        status: 'taken',
      );

      final doses = await c.read(dosesForDayProvider(today).future);
      expect(doses.map((d) => d.id), [taken]);
      expect(doses.any((d) => d.id == pending), isFalse);
    },
  );

  test('undoing a scheduled dose twice restores its stock once', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await db.update(
      'prescriptions',
      {'auto_diminish': 1},
      where: 'id = ?',
      whereArgs: [s.prescriptionId],
    );
    final id = await seedDoseLog(db, s.prescriptionId, recentToday(now));
    Future<int?> stock() async =>
        (await db.query(
              'medications',
              where: 'id = ?',
              whereArgs: [s.medicationId],
            )).single['quantity']
            as int?;
    final actions = c.read(doseActionsProvider);

    await actions.take(id);
    expect(await stock(), 9);
    expect(await actions.undoTake(id), isTrue);
    expect(await stock(), 10);
    expect(await actions.undoTake(id), isFalse);
    expect(await stock(), 10);
    // Undoing a dose that was never taken gives nothing back either.
    final pending = await seedDoseLog(db, s.prescriptionId, laterToday(now));
    expect(await actions.undoTake(pending), isFalse);
    expect(await stock(), 10);
  });

  test('undoTake restores pending and clears takenTime', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, laterToday(now));
    final actions = c.read(doseActionsProvider);
    await actions.take(a);
    await actions.undoTake(a);
    final dose = (await c.read(dosesForDayProvider(today).future)).single;
    expect(dose.status, DoseStatus.pending);
    expect(dose.takenTime, isNull);
  });

  test('a failed markDoseTaken leaves medication stock untouched', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await db.update(
      'prescriptions',
      {'auto_diminish': 1},
      where: 'id = ?',
      whereArgs: [s.prescriptionId],
    );
    final a = await seedDoseLog(db, s.prescriptionId, laterToday(now));

    final failing = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        nowProvider.overrideWithValue(() => now),
        doseLogRepositoryProvider.overrideWithValue(
          FailingTakeRepo(
            DoseLogRepositoryImpl(
              localDatasource: DoseLogLocalDatasource(),
              prescriptionLocal: PrescriptionLocalDatasource(),
            ),
          ),
        ),
      ],
    );
    addTearDown(failing.dispose);

    expect(await failing.read(doseActionsProvider).take(a), isFalse);

    final med = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [s.medicationId],
    );
    expect(med.single['quantity'], 10);
    final dose = await db.query('dose_logs', where: 'id = ?', whereArgs: [a]);
    expect(dose.single['status'], 'pending');
  });

  test(
    'invalidateDoseData makes dosesForDayProvider see writes made outside DoseActions',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(db, s.prescriptionId, laterToday(now));
      expect((await c.read(dosesForDayProvider(today).future)).length, 1);

      // What the prescription sheet does: write through the repositories,
      // never through DoseActions.
      final saved = await c
          .read(prescriptionRepositoryProvider)
          .addPrescription(
            Prescription(
              id: const Uuid().v4(),
              treatmentId: s.treatmentId,
              medicationId: s.medicationId,
              dosage: '1 tablets',
              dosageAmount: 1,
              intervalHours: 6,
              durationDays: 1,
              startTime: today.add(const Duration(hours: 9)),
            ),
          );
      final prescriptionId = saved.dataOrNull!.id;
      await c
          .read(doseLogRepositoryProvider)
          .generateDoseLogsForPrescription(prescriptionId);

      // Stale: nothing bumped the version, so the cached list is served.
      expect((await c.read(dosesForDayProvider(today).future)).length, 1);

      c.read(invalidateDoseDataProvider)();
      final after = await c.read(dosesForDayProvider(today).future);
      expect(after.length, greaterThan(1));
      expect(after.any((d) => d.prescriptionId == prescriptionId), isTrue);
    },
  );

  group('logAsNeededDose', () {
    // A clock distinct from the real one, so a dose stamped with
    // DateTime.now() instead of nowProvider cannot pass. Still today and in
    // the past, so the dose lands in today's list whatever the hour.
    final pinned = recentToday(
      now,
      minutes: 7,
    ).copyWith(millisecond: 123, microsecond: 0);

    Future<ProviderContainer> pinnedContainer({
      DoseLogRepository? doseRepo,
    }) async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          nowProvider.overrideWithValue(() => pinned),
          if (doseRepo != null)
            doseLogRepositoryProvider.overrideWithValue(doseRepo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<int> quantity(Database db, String medicationId) async {
      final med = await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [medicationId],
      );
      return med.single['quantity']! as int;
    }

    test('records one taken dose at the injected now', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      final container = await pinnedContainer();

      final id = await container
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);
      expect(id, isNotNull);

      final rows = await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [s.prescriptionId],
      );
      expect(rows, hasLength(1));
      expect(rows.single['id'], id);
      expect(rows.single['sync_status'], SyncStatus.pendingCreate);

      final logged = (await DoseLogLocalDatasource().getDoseLogById(id!))!;
      expect(logged.status, DoseStatus.taken);
      expect(logged.takenTime, pinned);
      expect(logged.scheduledTime, pinned);
    });

    test('each call records another dose', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      final actions = (await pinnedContainer()).read(doseActionsProvider);

      final a = await actions.logAsNeededDose(s.prescriptionId);
      final b = await actions.logAsNeededDose(s.prescriptionId);
      expect(a, isNot(b));
      final rows = await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [s.prescriptionId],
      );
      expect(rows, hasLength(2));
    });

    test(
      'shows as taken in today\'s lists and is never the next due dose',
      () async {
        final db = await AppDatabase.instance.database;
        final s = await seedPrescription(db, scheduleType: 'as_needed');
        final container = await pinnedContainer();
        // Build the list first, so the test also proves the action refreshes it.
        expect(await container.read(todaysDoseLogsProvider.future), isEmpty);

        final id = await container
            .read(doseActionsProvider)
            .logAsNeededDose(s.prescriptionId);

        final todays = await container.read(todaysDoseLogsProvider.future);
        expect(todays.map((d) => d.id), [id]);
        expect(todays.single.status, DoseStatus.taken);
        expect(container.read(nextDueDoseProvider), isNull);
        final day = await container.read(dosesForDayProvider(pinned).future);
        expect(day.map((d) => d.id), [id]);
      },
    );

    test('loading today\'s doses generates none for an as-needed '
        'prescription', () async {
      final db = await AppDatabase.instance.database;
      final midnight = DateTime(now.year, now.month, now.day);
      final asNeeded = await seedPrescription(
        db,
        scheduleType: 'as_needed',
        startTime: midnight,
      );
      // The fixed one is the control: its doses prove generation has run.
      final fixed = await seedPrescription(db, startTime: midnight);
      final container = await pinnedContainer();

      await container.read(todaysDoseLogsProvider.future);
      Future<int> count(String prescriptionId) async => (await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [prescriptionId],
      )).length;
      for (var i = 0; i < 100 && await count(fixed.prescriptionId) == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await count(fixed.prescriptionId), greaterThan(0));
      expect(await count(asNeeded.prescriptionId), 0);
    });

    test('runs auto-diminish with the prescription\'s amount', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1, 'dosage_amount': 2.0},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final container = await pinnedContainer();

      await container
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);

      expect(await quantity(db, s.medicationId), 8);
      final med = await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [s.medicationId],
      );
      // The absolute quantity, marked for the sync cycle to push.
      expect(med.single['sync_status'], SyncStatus.pendingUpdate);
    });

    test(
      'a dosage of "400 mg" takes one tablet, or one unit, from stock',
      () async {
        final db = await AppDatabase.instance.database;
        for (final unit in <String?>['tablets', null]) {
          final s = await seedPrescription(db, scheduleType: 'as_needed');
          await db.update(
            'prescriptions',
            {'auto_diminish': 1, 'dosage': '400 mg', 'dosage_amount': null},
            where: 'id = ?',
            whereArgs: [s.prescriptionId],
          );
          await db.update(
            'medications',
            {'quantity': 20, 'quantity_unit': unit},
            where: 'id = ?',
            whereArgs: [s.medicationId],
          );
          final container = await pinnedContainer();

          await container
              .read(doseActionsProvider)
              .logAsNeededDose(s.prescriptionId);

          expect(await quantity(db, s.medicationId), 19, reason: '$unit');
        }
      },
    );

    test('drops dosed from a bottle counted in drops take that many', () async {
      // Whether the amount is counted depends on the medication's own unit.
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {
          'auto_diminish': 1,
          'dosage': '20 drops',
          'dosage_amount': 20.0,
          'dosage_unit': 'drops',
        },
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      await db.update(
        'medications',
        {'quantity': 100, 'quantity_unit': 'drops'},
        where: 'id = ?',
        whereArgs: [s.medicationId],
      );
      final actions = (await pinnedContainer()).read(doseActionsProvider);

      await actions.logAsNeededDose(s.prescriptionId);
      expect(await quantity(db, s.medicationId), 80);

      // The same dose from a medication counted in ml is one unit.
      await db.update(
        'medications',
        {'quantity_unit': 'ml'},
        where: 'id = ?',
        whereArgs: [s.medicationId],
      );
      await actions.logAsNeededDose(s.prescriptionId);
      expect(await quantity(db, s.medicationId), 79);
    });

    test('logging a dose does not bring a deleted medication back', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final container = await pinnedContainer();
      await container
          .read(medicationRepositoryProvider)
          .deleteMedication(s.medicationId);

      await container
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);

      final med = (await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [s.medicationId],
      )).single;
      expect(med['sync_status'], SyncStatus.pendingDelete);
      expect(med['deleted_at'], isNotNull);
      expect(med['quantity'], 10);
      final list = await container
          .read(medicationRepositoryProvider)
          .getMedications();
      expect(list.dataOrNull, isEmpty);
    });

    test('leaves stock alone without auto-diminish', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      final container = await pinnedContainer();

      await container
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);

      expect(await quantity(db, s.medicationId), 10);
    });

    test('undoing it removes the dose and gives the stock back', () async {
      // Back to pending would leave a dose nobody is due to take; the
      // sync cycle deletes the tombstone on the server as well.
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final container = await pinnedContainer();
      final actions = container.read(doseActionsProvider);
      final kept = await actions.logAsNeededDose(s.prescriptionId);
      final id = await actions.logAsNeededDose(s.prescriptionId);
      expect(await quantity(db, s.medicationId), 8);

      expect(await actions.undoTake(id!), isTrue);

      expect(await quantity(db, s.medicationId), 9);
      final row = await db.query('dose_logs', where: 'id = ?', whereArgs: [id]);
      expect(row.single['sync_status'], SyncStatus.pendingDelete);
      expect(row.single['status'], 'taken');
      final todays = await container.read(todaysDoseLogsProvider.future);
      expect(todays.map((d) => d.id), [kept]);
      final day = await container.read(dosesForDayProvider(pinned).future);
      expect(day.map((d) => d.id), [kept]);
    });

    test('a second undo gives nothing back', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final actions = (await pinnedContainer()).read(doseActionsProvider);
      final id = await actions.logAsNeededDose(s.prescriptionId);
      expect(await quantity(db, s.medicationId), 9);

      expect(await actions.undoTake(id!), isTrue);
      expect(await quantity(db, s.medicationId), 10);
      // The snackbar's Undo after the dose sheet's, for example.
      expect(await actions.undoTake(id), isFalse);
      expect(await quantity(db, s.medicationId), 10);
    });

    test('a failed removal keeps the dose and the stock', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final id = await (await pinnedContainer())
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);
      final failing = await pinnedContainer(
        doseRepo: _FailingDeleteRepo(
          DoseLogRepositoryImpl(
            localDatasource: DoseLogLocalDatasource(),
            prescriptionLocal: PrescriptionLocalDatasource(),
          ),
        ),
      );

      expect(await failing.read(doseActionsProvider).undoTake(id!), isFalse);

      expect(await quantity(db, s.medicationId), 9);
      final row = await db.query('dose_logs', where: 'id = ?', whereArgs: [id]);
      expect(row.single['sync_status'], SyncStatus.pendingCreate);
      expect(row.single['status'], 'taken');
    });

    test('a failed write returns null and leaves stock alone', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      await db.update(
        'prescriptions',
        {'auto_diminish': 1},
        where: 'id = ?',
        whereArgs: [s.prescriptionId],
      );
      final container = await pinnedContainer(
        doseRepo: _FailingAddRepo(
          DoseLogRepositoryImpl(
            localDatasource: DoseLogLocalDatasource(),
            prescriptionLocal: PrescriptionLocalDatasource(),
          ),
        ),
      );

      final id = await container
          .read(doseActionsProvider)
          .logAsNeededDose(s.prescriptionId);

      expect(id, isNull);
      expect(await quantity(db, s.medicationId), 10);
      expect(await db.query('dose_logs'), isEmpty);
    });
  });
}

/// Fails every [addDoseLog]; everything else reaches the real repository.
class _FailingAddRepo extends FailingTakeRepo {
  _FailingAddRepo(super.inner);

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) async =>
      const Result.failure('db down');

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) => inner.markDoseTaken(id);
}

/// Fails every [deleteDoseLog]; everything else reaches the real repository.
class _FailingDeleteRepo extends FailingTakeRepo {
  _FailingDeleteRepo(super.inner);

  @override
  Future<Result<void>> deleteDoseLog(String id) async =>
      const Result.failure('db down');

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) => inner.markDoseTaken(id);
}
