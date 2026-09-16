/// The two schedulers against one notification port.
///
/// Each of them is covered on its own elsewhere; what only shows up here is
/// what they do to each other's notifications, which is where the release's
/// headline bug lived: the dose scheduler's recovery cancel took the stock
/// and expiry alerts with it on every cold start, and nothing re-booked them.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:medora/services/stock_alert_store.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
import 'package:medora/services/stock_reminder_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_reminder_port.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

Future<String> _seedMed(Database db, {required DateTime expiry}) async {
  const id = 'med-a';
  final ts = DateTime(2026).toIso8601String();
  await db.insert('medications', {
    'id': id,
    'name': 'Aspirin',
    'quantity': 10,
    'quantity_unit': 'tablets',
    'minimum_stock_level': 2,
    'expiry_date': expiry.toIso8601String().split('T').first,
    'is_archived': 0,
    'created_at': ts,
    'updated_at': ts,
    'sync_status': 'synced',
  });
  return id;
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 16, 10);

  ReminderScheduler doseScheduler(FakePort port, {bool enabled = true}) =>
      ReminderScheduler(
        port: port,
        doses: DoseLogRepositoryImpl(
          localDatasource: DoseLogLocalDatasource(),
          remoteDatasource: null,
          prescriptionLocal: PrescriptionLocalDatasource(),
        ),
        remindersEnabled: () => enabled,
        now: () => now,
      );

  StockReminderScheduler stockScheduler(
    FakePort port,
    StockAlertStore store, {
    bool enabled = true,
  }) => StockReminderScheduler(
    port: port,
    medications: MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      remoteDatasource: null,
    ),
    stockRemindersEnabled: () => enabled,
    now: () => now,
    store: store,
  );

  test('a cold start keeps the expiry alert the last session booked', () async {
    final db = await AppDatabase.instance.database;
    final med = await _seedMed(db, expiry: DateTime(2026, 12));
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 2)));

    final port = FakePort();
    final store = StockAlertStore.inMemory();
    final expiryId = stockAlertId(med, StockAlertKind.expiry);

    // Session one books the expiry alert for 1 Nov and persists it.
    expect(await stockScheduler(port, store).reconcile(), 1);
    expect(port.pendingStockAlertIds, {expiryId});

    // Session two: a cold start runs the dose scheduler first (see
    // app_startup_tasks), so its first-run recovery must leave the alert
    // alone — the stock scheduler's snapshot says it is already booked and
    // will never re-book it.
    expect(await doseScheduler(port).reconcile(), 1);
    expect(
      port.pendingStockAlertIds,
      {expiryId},
      reason: 'the dose reconcile cancelled the expiry alert',
    );

    await stockScheduler(port, store).reconcile();
    expect(
      port.pendingStockAlertIds,
      {expiryId},
      reason: 'nothing re-books it: its time never changes',
    );
  });

  test('turning the dose reminders off spares the stock alerts', () async {
    final db = await AppDatabase.instance.database;
    final med = await _seedMed(db, expiry: DateTime(2026, 12));

    final port = FakePort();
    final store = StockAlertStore.inMemory();
    await stockScheduler(port, store).reconcile();

    await doseScheduler(port, enabled: false).reconcile();

    expect(port.pendingStockAlertIds, {
      stockAlertId(med, StockAlertKind.expiry),
    });
  });
}
