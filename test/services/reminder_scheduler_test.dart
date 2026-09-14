import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/reminder_scheduler.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class FakePort implements ReminderPort {
  int cancelAllCalls = 0;
  final scheduled = <DoseLog>[];
  final cancelledDoses = <String>[];

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

  @override
  Future<void> cancelForDose(String doseId) async => cancelledDoses.add(doseId);

  @override
  Future<void> scheduleForDose({required DoseLog dose, required String medicationName}) async {
    scheduled.add(dose);
  }
}

class SlowPort extends FakePort {
  @override
  Future<void> scheduleForDose({required DoseLog dose, required String medicationName}) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await super.scheduleForDose(dose: dose, medicationName: medicationName);
  }
}

/// A [DoseLogRepository] whose only implemented member fails; every other
/// call is unreachable in these tests, so it throws via [noSuchMethod].
class _FailingDoses implements DoseLogRepository {
  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(DateTime start, DateTime end) async {
    return const Result.failure('db down');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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

  test('a reconcile requested during a run is executed afterwards, not dropped', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = SlowPort();
    final scheduler = make(port);
    final first = scheduler.reconcile();
    final second = scheduler.reconcile(); // arrives while first is running
    // Seeded before the rerun query runs (but after the first pass has
    // already started), so the merged-in rerun is the one that observes it —
    // proof that it ran after the first pass completed, not that it was
    // dropped.
    final extra = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 5)));
    final results = await Future.wait([first, second]);
    // Diff-based reconcile: only the first pass is a full cancel; the rerun
    // is incremental and only schedules the newly-seeded dose.
    expect(port.cancelAllCalls, 1, reason: 'only the first pass does a full cancel');
    expect(results[0], 2, reason: 'outer call returns the count after both passes complete');
    expect(results[1], 0, reason: 'the merged-in request returns immediately without doing work');
    expect(port.scheduled.map((d) => d.id), contains(extra),
        reason: 'the rerun picked up the dose seeded after the first pass started');
  });

  test('getPendingBetween only schedules doses from active prescriptions', () async {
    final db = await AppDatabase.instance.database;
    final s1 = await seedPrescription(db);
    final s2 = await seedPrescription(db);
    await db.update('prescriptions', {'is_active': 0},
        where: 'id = ?', whereArgs: [s2.prescriptionId]);
    await seedDoseLog(db, s1.prescriptionId, now.add(const Duration(hours: 1)));
    await seedDoseLog(db, s2.prescriptionId, now.add(const Duration(hours: 2)));

    final port = FakePort();
    final count = await make(port).reconcile();

    expect(count, 1);
    expect(port.scheduled.length, 1);
  });

  test('second reconcile only cancels removed and schedules added doses', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final b = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 2)));
    final port = FakePort();
    final scheduler = make(port);

    await scheduler.reconcile();
    expect(port.cancelAllCalls, 1);
    expect(port.scheduled.map((d) => d.id).toList(), [a, b]);

    // a is taken, c appears
    await db.update('dose_logs', {'status': 'taken'}, where: 'id = ?', whereArgs: [a]);
    final c = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 3)));
    port.scheduled.clear();

    final count = await scheduler.reconcile();
    expect(port.cancelAllCalls, 1, reason: 'no full cancel on incremental run');
    expect(port.cancelledDoses, [a]);
    expect(port.scheduled.map((d) => d.id).toList(), [c]);
    expect(count, 2);
  });

  test('reset() forces a full cancel on the next reconcile', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = FakePort();
    final scheduler = make(port);
    await scheduler.reconcile();
    scheduler.reset();
    await scheduler.reconcile();
    expect(port.cancelAllCalls, 2);
  });

  test('a dose whose scheduled time changed is cancelled and re-scheduled', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = FakePort();
    final scheduler = make(port);

    await scheduler.reconcile();
    expect(port.scheduled.map((d) => d.id).toList(), [a]);

    final newTime = now.add(const Duration(hours: 4));
    await db.update('dose_logs', {'scheduled_time': newTime.toIso8601String()},
        where: 'id = ?', whereArgs: [a]);
    port.scheduled.clear();

    await scheduler.reconcile();
    expect(port.cancelledDoses, [a]);
    expect(port.scheduled.single.id, a);
    expect(port.scheduled.single.scheduledTime, newTime);
  });

  test('query failure keeps the previous snapshot and cancels nothing', () async {
    final port = FakePort();
    final scheduler = ReminderScheduler(
      port: port,
      doses: _FailingDoses(),
      remindersEnabled: () => true,
      now: () => now,
    );

    final count = await scheduler.reconcile();

    expect(port.cancelAllCalls, 0);
    expect(port.scheduled, isEmpty);
    expect(count, 0);
  });
}
