import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_reminder_port.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

/// Repository stub whose pending-dose query resolves only when the test says so.
class _GatedDoses implements DoseLogRepository {
  final calls = <Completer<Result<List<DoseLog>>>>[];

  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(
    DateTime start,
    DateTime end,
  ) {
    final c = Completer<Result<List<DoseLog>>>();
    calls.add(c);
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

DoseLog _dose(String id, DateTime at) => DoseLog(
  id: id,
  prescriptionId: 'p',
  scheduledTime: at,
  medicationName: 'M',
);

/// A [DoseLogRepository] whose only implemented member fails; every other
/// call is unreachable in these tests, so it throws via [noSuchMethod].
class _FailingDoses implements DoseLogRepository {
  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(
    DateTime start,
    DateTime end,
  ) async {
    return const Result.failure('db down');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 3, 1, 9);

  ReminderScheduler make(FakePort port, {bool enabled = true}) =>
      ReminderScheduler(
        port: port,
        doses: DoseLogRepositoryImpl(
          localDatasource: DoseLogLocalDatasource(),
          prescriptionLocal: PrescriptionLocalDatasource(),
        ),
        remindersEnabled: () => enabled,
        now: () => now,
      );

  test(
    'schedules only pending doses inside the 7-day horizon, earliest first',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.subtract(const Duration(hours: 1)),
      ); // past → skipped
      final soon = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 2)),
      );
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 3)),
        status: 'taken',
      ); // not pending
      final later = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(days: 6)),
      );
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(days: 8)),
      ); // beyond horizon

      final port = FakePort();
      final count = await make(port).reconcile();

      expect(port.cancelAllDosesCalls, 1);
      expect(count, 2);
      expect(port.scheduled.map((d) => d.id).toList(), [soon, later]);
    },
  );

  test('caps at maxNotifications / notificationsPerDose doses', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    for (var i = 1; i <= 40; i++) {
      await seedDoseLog(db, s.prescriptionId, now.add(Duration(hours: i)));
    }
    final port = FakePort();
    final count = await make(port).reconcile();
    expect(
      count,
      ReminderScheduler.maxNotifications ~/
          ReminderScheduler.notificationsPerDose,
    );
    expect(
      port.scheduled.length,
      ReminderScheduler.maxNotifications ~/
          ReminderScheduler.notificationsPerDose,
    );
    expect(
      port.scheduled.first.scheduledTime,
      now.add(const Duration(hours: 1)),
    );
  });

  test(
    'when reminders are disabled it cancels and schedules nothing',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      final port = FakePort();
      final count = await make(port, enabled: false).reconcile();
      expect(port.cancelAllDosesCalls, 1);
      expect(count, 0);
      expect(port.scheduled, isEmpty);
    },
  );

  test(
    'a reconcile requested during a run is executed afterwards with fresh data',
    () async {
      final port = FakePort();
      final doses = _GatedDoses();
      final scheduler = ReminderScheduler(
        port: port,
        doses: doses,
        remindersEnabled: () => true,
        now: () => now,
      );

      final first = scheduler.reconcile();
      await Future<void>.delayed(Duration.zero); // let pass 1 reach its query
      expect(doses.calls.length, 1);
      final second = scheduler
          .reconcile(); // arrives while pass 1 is blocked → rerun flag
      expect(await second, 0); // coalesced call returns immediately

      doses.calls[0].complete(
        Result.success([_dose('a', now.add(const Duration(hours: 1)))]),
      );
      // pass 1 finishes, rerun starts and blocks on query 2. A few awaits
      // separate the completion from the rerun's query (schedule loop with
      // FakePort's async no-ops), so poll rather than relying on one delay.
      var iterations = 0;
      while (doses.calls.length < 2) {
        await Future<void>.delayed(Duration.zero);
        iterations++;
        if (iterations > 100) {
          fail('rerun never issued a second query');
        }
      }
      expect(doses.calls.length, 2, reason: 'rerun must issue a second query');
      doses.calls[1].complete(
        Result.success([
          _dose('a', now.add(const Duration(hours: 1))),
          _dose('b', now.add(const Duration(hours: 2))),
        ]),
      );

      expect(await first, 2);
      expect(
        port.cancelAllDosesCalls,
        1,
        reason: 'only the first pass does a full cancel',
      );
      expect(
        port.scheduled.map((d) => d.id).toList(),
        ['a', 'b'],
        reason: 'rerun scheduled the dose that appeared after pass 1 queried',
      );
    },
  );

  test(
    'getPendingBetween only schedules doses from active prescriptions',
    () async {
      final db = await AppDatabase.instance.database;
      final s1 = await seedPrescription(db);
      final s2 = await seedPrescription(db);
      await db.update(
        'prescriptions',
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: [s2.prescriptionId],
      );
      await seedDoseLog(
        db,
        s1.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      await seedDoseLog(
        db,
        s2.prescriptionId,
        now.add(const Duration(hours: 2)),
      );

      final port = FakePort();
      final count = await make(port).reconcile();

      expect(count, 1);
      expect(port.scheduled.length, 1);
    },
  );

  test(
    'second reconcile only cancels removed and schedules added doses',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final a = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      final b = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 2)),
      );
      final port = FakePort();
      final scheduler = make(port);

      await scheduler.reconcile();
      expect(port.cancelAllDosesCalls, 1);
      expect(port.scheduled.map((d) => d.id).toList(), [a, b]);

      // a is taken, c appears
      await db.update(
        'dose_logs',
        {'status': 'taken'},
        where: 'id = ?',
        whereArgs: [a],
      );
      final c = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 3)),
      );
      port.scheduled.clear();

      final count = await scheduler.reconcile();
      expect(
        port.cancelAllDosesCalls,
        1,
        reason: 'no full cancel on incremental run',
      );
      expect(port.cancelledDoses, [a]);
      expect(port.scheduled.map((d) => d.id).toList(), [c]);
      expect(count, 2);
    },
  );

  test('reset() forces a full cancel on the next reconcile', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = FakePort();
    final scheduler = make(port);
    await scheduler.reconcile();
    scheduler.reset();
    await scheduler.reconcile();
    expect(port.cancelAllDosesCalls, 2);
  });

  test(
    'a dose whose scheduled time changed is cancelled and re-scheduled',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final a = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      final port = FakePort();
      final scheduler = make(port);

      await scheduler.reconcile();
      expect(port.scheduled.map((d) => d.id).toList(), [a]);

      final newTime = now.add(const Duration(hours: 4));
      await db.update(
        'dose_logs',
        {'scheduled_time': newTime.toIso8601String()},
        where: 'id = ?',
        whereArgs: [a],
      );
      port.scheduled.clear();

      await scheduler.reconcile();
      expect(port.cancelledDoses, [a]);
      expect(port.scheduled.single.id, a);
      expect(port.scheduled.single.scheduledTime, newTime);
    },
  );

  test(
    'query failure keeps the previous snapshot and cancels nothing',
    () async {
      final port = FakePort();
      final scheduler = ReminderScheduler(
        port: port,
        doses: _FailingDoses(),
        remindersEnabled: () => true,
        now: () => now,
      );

      expect(scheduler.lastError, isNull);
      final count = await scheduler.reconcile();

      expect(port.cancelAllDosesCalls, 0);
      expect(port.scheduled, isEmpty);
      expect(count, 0);
      expect(
        scheduler.lastError,
        'db down',
        reason: 'the repository failure message must reach lastError intact',
      );
    },
  );

  test(
    'a port failure mid-reconcile keeps the previous count and sets lastError',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      final port = FakePort();
      final scheduler = make(port);

      final first = await scheduler.reconcile();
      expect(first, 1);
      expect(scheduler.lastError, isNull);

      port.throwOnSchedule = true;
      await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 2)),
      );

      final second = await scheduler.reconcile();

      expect(
        scheduler.lastError,
        contains('scheduleForDose failed'),
        reason: 'the port failure message must reach lastError intact',
      );
      expect(
        second,
        1,
        reason: 'previous snapshot count is kept when the port fails',
      );
    },
  );

  test('lastError is cleared once a later reconcile succeeds', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final port = FakePort()..throwOnSchedule = true;
    final scheduler = make(port);

    await scheduler.reconcile();
    expect(scheduler.lastError, contains('scheduleForDose failed'));

    port.throwOnSchedule = false;
    final count = await scheduler.reconcile();

    expect(count, 1);
    expect(scheduler.lastError, isNull);
  });

  group('locale changes', () {
    test('re-schedule every queued reminder in the new language', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      // The provider-built scheduler uses the real clock, so seed relative
      // to it rather than to the fixed `now` above.
      await seedDoseLog(
        db,
        s.prescriptionId,
        DateTime.now().add(const Duration(hours: 2)),
      );

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final port = FakePort();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          reminderPortProvider.overrideWithValue(port),
        ],
      );
      addTearDown(container.dispose);

      final scheduler = container.read(reminderSchedulerProvider);
      expect(await scheduler.reconcile(), 1);
      expect(port.cancelAllDosesCalls, 1);
      expect(port.scheduled, hasLength(1));

      // The notification body is built at schedule time from the current
      // locale, so the queued reminders have to be rebuilt.
      await container.read(localeProvider.notifier).set(const Locale('de'));
      await _until(() => port.cancelAllDosesCalls == 2);

      expect(
        port.cancelAllDosesCalls,
        2,
        reason: 'the snapshot is dropped, so the next run cancels everything',
      );
      expect(
        port.scheduled,
        hasLength(2),
        reason: 'the dose is scheduled again, now in German',
      );
    });

    test('an unchanged locale does not re-schedule', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(
        db,
        s.prescriptionId,
        DateTime.now().add(const Duration(hours: 2)),
      );

      SharedPreferences.setMockInitialValues({'locale': 'de'});
      final prefs = await SharedPreferences.getInstance();
      final port = FakePort();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          reminderPortProvider.overrideWithValue(port),
        ],
      );
      addTearDown(container.dispose);

      await container.read(reminderSchedulerProvider).reconcile();
      await container.read(localeProvider.notifier).set(const Locale('de'));
      await _until(() => false, timeout: const Duration(milliseconds: 100));

      expect(port.cancelAllDosesCalls, 1);
      expect(port.scheduled, hasLength(1));
    });
  });
}

/// Pumps the event queue until [done] or [timeout]; the listener fires and
/// reconciles asynchronously.
Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
  }
}
