import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
import 'package:medora/services/stock_reminder_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../helpers/fake_reminder_port.dart';
import '../helpers/test_database.dart';

const _uuid = Uuid();

/// Inserts one medication row and returns its id.
Future<String> _seedMed(
  Database db, {
  String name = 'Aspirin',
  int quantity = 10,
  int minimumStockLevel = 2,
  DateTime? expiryDate,
  bool isArchived = false,
}) async {
  final id = _uuid.v4();
  final ts = DateTime(2026).toIso8601String();
  await db.insert('medications', {
    'id': id,
    'name': name,
    'quantity': quantity,
    'quantity_unit': 'tablets',
    'minimum_stock_level': minimumStockLevel,
    'expiry_date': expiryDate?.toIso8601String().split('T').first,
    'is_archived': isArchived ? 1 : 0,
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

  MedicationRepository repo() => MedicationRepositoryImpl(
    localDatasource: MedicationLocalDatasource(),
    remoteDatasource: null,
  );

  test('disabled: schedules nothing and cancels what it had', () async {
    final db = await AppDatabase.instance.database;
    final low = await _seedMed(db, quantity: 1);

    final port = FakePort();
    var enabled = true;
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => enabled,
      now: () => now,
    );

    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts, hasLength(1));

    enabled = false;
    expect(await scheduler.reconcile(), 0);
    expect(port.cancelledStockAlerts, [
      stockAlertId(low, StockAlertKind.lowStock),
    ]);
    expect(
      port.stockAlerts,
      hasLength(1),
      reason: 'nothing new is scheduled while the setting is off',
    );
  });

  test('schedules one alert per medication and kind, by planned id', () async {
    final db = await AppDatabase.instance.database;
    final low = await _seedMed(db, name: 'A', quantity: 1);
    final soon = await _seedMed(db, name: 'B', expiryDate: DateTime(2026, 10));

    final port = FakePort();
    final count = await StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    ).reconcile();

    expect(count, 2);
    expect(port.stockAlerts.map((a) => a.id).toSet(), {
      stockAlertId(low, StockAlertKind.lowStock),
      stockAlertId(soon, StockAlertKind.expiry),
    });
    expect(
      port.cancelledStockAlerts,
      isEmpty,
      reason: 'the first run must not touch the dose reminders',
    );
  });

  test('a second reconcile with no change schedules nothing more', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 1);

    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    );

    expect(await scheduler.reconcile(), 1);
    port.stockAlerts.clear();

    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts, isEmpty);
    expect(port.cancelledStockAlerts, isEmpty);
  });

  test('restocking above the minimum cancels the low-stock alert', () async {
    final db = await AppDatabase.instance.database;
    final id = await _seedMed(db, quantity: 1);

    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    );
    await scheduler.reconcile();

    await db.update(
      'medications',
      {'quantity': 20},
      where: 'id = ?',
      whereArgs: [id],
    );

    expect(await scheduler.reconcile(), 0);
    expect(port.cancelledStockAlerts, [
      stockAlertId(id, StockAlertKind.lowStock),
    ]);
  });

  test('a changed expiry cancels and re-schedules the alert', () async {
    final db = await AppDatabase.instance.database;
    final id = await _seedMed(db, expiryDate: DateTime(2026, 12));

    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    );
    await scheduler.reconcile();
    expect(port.stockAlerts.single.when, DateTime(2026, 11, 1, 9));
    port.stockAlerts.clear();

    await db.update(
      'medications',
      {'expiry_date': '2026-12-20'},
      where: 'id = ?',
      whereArgs: [id],
    );

    expect(await scheduler.reconcile(), 1);
    expect(port.cancelledStockAlerts, [
      stockAlertId(id, StockAlertKind.expiry),
    ]);
    expect(port.stockAlerts.single.when, DateTime(2026, 11, 20, 9));
  });

  test('reset() forgets the snapshot and schedules everything again', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 1);

    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    );
    await scheduler.reconcile();
    port.stockAlerts.clear();

    scheduler.reset();
    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts, hasLength(1));
  });

  test('archived medications raise no alert', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 0, isArchived: true);

    final port = FakePort();
    final count = await StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    ).reconcile();

    expect(count, 0);
    expect(port.stockAlerts, isEmpty);
  });
}
