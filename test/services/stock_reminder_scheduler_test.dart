import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/notification_budget.dart';
import 'package:medora/services/stock_alert_store.dart';
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

/// A repository whose load hangs until the test completes it, so two
/// reconciles can be made to overlap deliberately.
class _GatedMeds implements MedicationRepository {
  final calls = <Completer<Result<List<Medication>>>>[];

  @override
  Future<Result<List<Medication>>> getMedications() {
    final completer = Completer<Result<List<Medication>>>();
    calls.add(completer);
    return completer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Serves [_inner] until [fail] is set, then fails every load.
class _FlakyMeds implements MedicationRepository {
  _FlakyMeds(this._inner);

  final MedicationRepository _inner;
  bool fail = false;

  @override
  Future<Result<List<Medication>>> getMedications() async =>
      fail ? const Result.failure('db down') : _inner.getMedications();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Medication _lowStock(String id) => Medication(
  id: id,
  name: 'Aspirin',
  quantity: 0,
  minimumStockLevel: 2,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 16, 10);

  MedicationRepository repo() =>
      MedicationRepositoryImpl(localDatasource: MedicationLocalDatasource());

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

  test('a changed quantity re-books the alert at the same time', () async {
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
    expect(port.stockAlerts.single.quantity, 1);
    port.stockAlerts.clear();

    // The last two tablets are taken. The alert still fires at 09:00
    // tomorrow, but its text was baked in when it was booked, so leaving it
    // alone means the phone says "1 left" for an empty box.
    await db.update(
      'medications',
      {'quantity': 0},
      where: 'id = ?',
      whereArgs: [id],
    );

    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts.single.quantity, 0);
  });

  test('a renamed medication re-books the alert', () async {
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
    port.stockAlerts.clear();

    await db.update(
      'medications',
      {'name': 'Aspirina'},
      where: 'id = ?',
      whereArgs: [id],
    );

    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts.single.medicationName, 'Aspirina');
  });

  test('reset() still knows last session\'s ids', () async {
    final db = await AppDatabase.instance.database;
    final id = await _seedMed(db, quantity: 1);
    final store = StockAlertStore.inMemory();
    final port = FakePort();

    await StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
      store: store,
    ).reconcile();

    await db.update(
      'medications',
      {'quantity': 20},
      where: 'id = ?',
      whereArgs: [id],
    );

    // A reset before this session's first reconcile (the locale listener, a
    // restore, "Cancel All Reminders") must not throw away the stored ids:
    // they are the only handle on an alert the cabinet no longer wants.
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
      store: store,
    )..reset();

    expect(await scheduler.reconcile(), 0);
    expect(port.cancelledStockAlerts, [
      stockAlertId(id, StockAlertKind.lowStock),
    ]);
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

  test(
    'a restart still cancels an alert the cabinet no longer wants',
    () async {
      final db = await AppDatabase.instance.database;
      final id = await _seedMed(db, quantity: 1);
      final store = StockAlertStore.inMemory();
      final port = FakePort();

      StockReminderScheduler restart() => StockReminderScheduler(
        port: port,
        medications: repo(),
        stockRemindersEnabled: () => true,
        now: () => now,
        store: store,
      );

      expect(await restart().reconcile(), 1);

      await db.update(
        'medications',
        {'quantity': 20},
        where: 'id = ?',
        whereArgs: [id],
      );

      // A fresh instance is a fresh process. Without a persisted snapshot it
      // has no memory of the id, cancels nothing, and tomorrow morning the
      // phone announces "1 left" for a full box.
      expect(await restart().reconcile(), 0);
      expect(port.cancelledStockAlerts, [
        stockAlertId(id, StockAlertKind.lowStock),
      ]);
    },
  );

  test(
    'a restart with the setting off cancels what the last session booked',
    () async {
      final db = await AppDatabase.instance.database;
      final id = await _seedMed(db, quantity: 1);
      final store = StockAlertStore.inMemory();
      final port = FakePort();

      await StockReminderScheduler(
        port: port,
        medications: repo(),
        stockRemindersEnabled: () => true,
        now: () => now,
        store: store,
      ).reconcile();

      expect(
        await StockReminderScheduler(
          port: port,
          medications: repo(),
          stockRemindersEnabled: () => false,
          now: () => now,
          store: store,
        ).reconcile(),
        0,
      );
      expect(port.cancelledStockAlerts, [
        stockAlertId(id, StockAlertKind.lowStock),
      ]);
    },
  );

  test('overlapping reconciles do not corrupt the snapshot', () async {
    final meds = _GatedMeds();
    final port = FakePort();
    var enabled = true;
    final scheduler = StockReminderScheduler(
      port: port,
      medications: meds,
      stockRemindersEnabled: () => enabled,
      now: () => now,
    );

    final startup = scheduler.reconcile();
    await pumpEventQueue();
    expect(meds.calls, hasLength(1));

    // The user flips the switch off while the startup run waits on the DB.
    enabled = false;
    final fromSettings = scheduler.reconcile();
    meds.calls.single.complete(Result.success([_lowStock('a')]));
    await Future.wait([startup, fromSettings]);

    final id = stockAlertId('a', StockAlertKind.lowStock);
    expect(port.stockAlerts.map((a) => a.id), [id]);
    expect(
      port.cancelledStockAlerts,
      [id],
      reason: 'the rerun saw the switch was off and took back what it booked',
    );

    // The snapshot has to be empty now, not full of alerts that were cancelled.
    enabled = true;
    final again = scheduler.reconcile();
    await pumpEventQueue();
    meds.calls.last.complete(Result.success([_lowStock('a')]));
    expect(await again, 1);
    expect(port.stockAlerts, hasLength(2));
  });

  test(
    'nothing is scheduled while notification permission is denied',
    () async {
      final db = await AppDatabase.instance.database;
      await _seedMed(db, quantity: 1);

      final port = FakePort()..permissionGranted = false;
      final scheduler = StockReminderScheduler(
        port: port,
        medications: repo(),
        stockRemindersEnabled: () => true,
        now: () => now,
      );

      expect(await scheduler.reconcile(), 0);
      expect(port.stockAlerts, isEmpty);
      expect(port.ensurePermissionsCalls, 1);

      // Granted later in system settings: the next reconcile just works.
      port.permissionGranted = true;
      expect(await scheduler.reconcile(), 1);
      expect(port.stockAlerts, hasLength(1));
    },
  );

  test('permission is not asked when there is nothing to schedule', () async {
    final port = FakePort();
    final count = await StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    ).reconcile();

    expect(count, 0);
    expect(
      port.ensurePermissionsCalls,
      0,
      reason: 'an empty cabinet must not raise a permission dialog',
    );
  });

  test('a failed load keeps the snapshot rather than cancelling', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 1);

    final meds = _FlakyMeds(repo());
    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: meds,
      stockRemindersEnabled: () => true,
      now: () => now,
    );
    expect(await scheduler.reconcile(), 1);

    meds.fail = true;
    expect(await scheduler.reconcile(), 1);
    expect(port.cancelledStockAlerts, isEmpty);
    expect(port.stockAlerts, hasLength(1));
  });

  test('a port failure is retried on the next run', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 1);

    final port = FakePort()..throwOnSchedule = true;
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
    );
    expect(await scheduler.reconcile(), 0);
    expect(port.stockAlerts, isEmpty);

    port.throwOnSchedule = false;
    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts, hasLength(1));
  });

  RxWithDispensings openRx(String id, DateTime validUntil) => RxWithDispensings(
    Rx(
      id: id,
      personId: 'p1',
      kind: RxKind.ssn,
      issuedOn: now,
      validUntil: validUntil,
      items: const [RxItem(id: 'i1', description: 'Brufen')],
    ),
    const [],
  );
  const persons = {'p1': Person(id: 'p1', name: 'Ben')};

  test(
    'prescription-expiry alerts are booked alongside stock alerts',
    () async {
      final port = FakePort();
      final scheduler = StockReminderScheduler(
        port: port,
        medications: repo(),
        stockRemindersEnabled: () => true,
        now: () => now,
        rxInputs: () async => RxReminderInputs(
          rx: [openRx('r1', DateTime(2026, 9, 20))],
          persons: persons,
          plannedMedicationIds: const {},
        ),
      );

      expect(await scheduler.reconcile(), 1);
      expect(port.stockAlerts.single.kind, StockAlertKind.rxExpiry);
      expect(port.stockAlerts.single.medicationId, 'r1');
    },
  );

  test('a failing rx load plans no rx alerts but keeps stock alerts', () async {
    final db = await AppDatabase.instance.database;
    await _seedMed(db, quantity: 1);

    final port = FakePort();
    final scheduler = StockReminderScheduler(
      port: port,
      medications: repo(),
      stockRemindersEnabled: () => true,
      now: () => now,
      rxInputs: () async => throw StateError('rx load failed'),
    );

    expect(await scheduler.reconcile(), 1);
    expect(port.stockAlerts.single.kind, StockAlertKind.lowStock);
  });

  test(
    'the merged stock and prescription alerts still honour the budget',
    () async {
      final db = await AppDatabase.instance.database;
      for (var i = 0; i < kStockNotificationBudget; i++) {
        await _seedMed(db, name: 'm$i', quantity: 0);
      }

      final port = FakePort();
      final scheduler = StockReminderScheduler(
        port: port,
        medications: repo(),
        stockRemindersEnabled: () => true,
        now: () => now,
        rxInputs: () async => RxReminderInputs(
          // Far enough out that its lead window opens well after every
          // low-stock alert's "as soon as possible" slot, so it is the one
          // the budget drops rather than crowding out a nearer alert.
          rx: [openRx('r1', DateTime(now.year, now.month, now.day + 30))],
          persons: persons,
          plannedMedicationIds: const {},
        ),
      );

      expect(await scheduler.reconcile(), kStockNotificationBudget);
      expect(
        port.stockAlerts.any((a) => a.kind == StockAlertKind.rxExpiry),
        isFalse,
        reason:
            'every low-stock alert is due sooner, so the shared budget keeps '
            'them over a prescription still weeks from its own window',
      );
    },
  );
}
