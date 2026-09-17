import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/local_data_wiper.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class _Port implements ReminderPort {
  int cancels = 0;
  @override
  Future<void> cancelAll() async => cancels++;
  @override
  Future<void> cancelAllDoses() async {}
  @override
  Future<void> cancelForDose(String doseId) async {}
  @override
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {}
  @override
  Future<void> scheduleStockAlert(StockAlert alert) async {}
  @override
  Future<void> cancelStockAlert(int id) async {}
  @override
  Future<bool> ensurePermissions() async => true;
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test(
    'wipe cancels reminders, deletes photos and rows, keeps AIFA prefs',
    () async {
      final root = await Directory.systemTemp.createTemp('medora_wipe_');
      addTearDown(() => root.delete(recursive: true));
      final photos = PhotoStorage(rootDirectory: () async => root);
      final name = await photos.saveFromPath(
        (File(p.join(root.path, 'a.jpg'))..writeAsBytesSync([1])).path,
      );

      SharedPreferences.setMockInitialValues({
        'aifa_count': 5,
        'app_mode': 'cloud',
        'theme_mode': 'dark',
      });
      final prefs = await SharedPreferences.getInstance();

      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(db, s.prescriptionId, DateTime(2026, 3, 1, 8));
      await db.insert('stock_outbox', {
        'op_id': 'op1',
        'medication_id': s.medicationId,
        'delta': -1,
        'created_at': '2026-03-05T08:00:00.000Z',
      });

      final port = _Port();
      await LocalDataWiper(
        database: AppDatabase.instance,
        photos: photos,
        reminders: port,
        prefs: prefs,
      ).wipe();

      expect(port.cancels, 1);
      expect(await photos.resolve(name), isNull);
      for (final t in [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
        'stock_outbox',
      ]) {
        expect(await db.query(t), isEmpty, reason: t);
      }
      expect(prefs.getInt('aifa_count'), 5);
      expect(prefs.getString('theme_mode'), 'dark');
    },
  );

  test(
    'wipe completes and clears the database even when photo cleanup fails',
    () async {
      final photos = PhotoStorage(
        rootDirectory: () async => throw StateError('no fs'),
      );

      SharedPreferences.setMockInitialValues({
        'aifa_count': 5,
        'app_mode': 'cloud',
        'theme_mode': 'dark',
      });
      final prefs = await SharedPreferences.getInstance();

      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      await seedDoseLog(db, s.prescriptionId, DateTime(2026, 3, 1, 8));
      await db.insert('stock_outbox', {
        'op_id': 'op1',
        'medication_id': s.medicationId,
        'delta': -1,
        'created_at': '2026-03-05T08:00:00.000Z',
      });

      final port = _Port();
      await LocalDataWiper(
        database: AppDatabase.instance,
        photos: photos,
        reminders: port,
        prefs: prefs,
      ).wipe();

      expect(port.cancels, 1);
      for (final t in [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
        'stock_outbox',
      ]) {
        expect(await db.query(t), isEmpty, reason: t);
      }
      expect(prefs.getInt('aifa_count'), 5);
      expect(prefs.getString('theme_mode'), 'dark');
    },
  );

  test('wipe removes sync pull cursors and failure records but keeps other '
      'prefs', () async {
    SharedPreferences.setMockInitialValues({
      'sync.last_pull_at.medications': '2026-01-01T00:00:00.000Z',
      'sync.pull_key.dose_logs': '1234|d1',
      'theme_mode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();
    final failures = SyncFailureStore(prefs);
    await failures.recordFailure('medications', 'm1', DateTime.utc(2026));
    final photos = PhotoStorage(
      rootDirectory: () async => throw StateError('no fs'),
    );
    final port = _Port();

    await LocalDataWiper(
      database: AppDatabase.instance,
      photos: photos,
      reminders: port,
      prefs: prefs,
    ).wipe();

    expect(prefs.getString('${SyncCursorStore.keyPrefix}medications'), isNull);
    expect(
      prefs.getString('${SyncCursorStore.pullKeyPrefix}dose_logs'),
      isNull,
    );
    expect(await failures.listAll(), isEmpty);
    expect(
      prefs.getKeys().where((k) => k.startsWith(SyncFailureStore.keyPrefix)),
      isEmpty,
    );
    expect(prefs.getString('theme_mode'), 'dark');
  });
}
