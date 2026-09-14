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
