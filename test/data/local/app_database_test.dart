import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/migrations.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

Future<Set<String>> columnsOf(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('fresh database has all tables and records every migration as applied', () async {
    final db = await AppDatabase.instance.database;
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((r) => r['name'] as String).toSet();

    expect(tables, containsAll(['medications', 'treatments', 'prescriptions', 'dose_logs', 'families', 'family_members', 'schema_migrations']));
    expect(await AppDatabase.instance.appliedMigrations(), kMigrations.map((m) => m.version).toList());
  });

  test('migration 11 adds deleted_at to synced tables', () async {
    final db = await AppDatabase.instance.database;
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      expect(await columnsOf(db, table), contains('deleted_at'), reason: table);
    }
  });

  test('upgrading a v10 database applies pending migrations exactly once', () async {
    // Build a v10 file database with the legacy schema, then reopen through AppDatabase.
    final dir = await Directory.systemTemp.createTemp('medora_mig_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 10, onCreate: (db, _) => AppDatabase.createBaseSchema(db)),
    );
    expect(await columnsOf(legacy, 'medications'), isNot(contains('deleted_at')));
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final upgraded = await AppDatabase.instance.database;

    expect(await columnsOf(upgraded, 'medications'), contains('deleted_at'));
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12, 13]);

    // Reopen: nothing re-applied, no duplicate rows.
    await AppDatabase.instance.reset();
    final again = await AppDatabase.instance.database;
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12, 13]);
    await again.close();
    await dir.delete(recursive: true);
  });

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
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12, 13]);
    await AppDatabase.instance.reset();
    await dir.delete(recursive: true);
  });

  test('migration 13 rewrites Z-suffixed dose timestamps as local naive strings', () async {
    final dir = await Directory.systemTemp.createTemp('medora_mig13_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 12,
        onCreate: (db, _) async {
          await AppDatabase.createBaseSchema(db);
          await kMigrations[0].run(db);
          await kMigrations[1].run(db);
        },
      ),
    );
    await legacy.insert('medications', {'id': 'm', 'name': 'M', 'quantity': 1});
    await legacy.insert('treatments', {'id': 't', 'name': 'T', 'start_date': '2026-03-01', 'is_active': 1});
    await legacy.insert('prescriptions', {
      'id': 'p', 'treatment_id': 't', 'medication_id': 'm', 'dosage': '1', 'start_time': '2026-03-01T08:00:00.000',
    });
    await legacy.insert('dose_logs', {'id': 'z', 'prescription_id': 'p', 'scheduled_time': '2026-03-01T07:00:00.000Z', 'status': 'pending'});
    await legacy.insert('dose_logs', {'id': 'n', 'prescription_id': 'p', 'scheduled_time': '2026-03-01T08:00:00.000', 'status': 'pending'});
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final db = await AppDatabase.instance.database;
    final rows = {for (final r in await db.query('dose_logs')) r['id']: r['scheduled_time'] as String};
    expect(rows['n'], '2026-03-01T08:00:00.000');
    expect(rows['z'], isNot(endsWith('Z')));
    expect(DateTime.parse(rows['z']!), DateTime.utc(2026, 3, 1, 7).toLocal());
    expect(await AppDatabase.instance.appliedMigrations(), [11, 12, 13]);
    await AppDatabase.instance.reset();
    await dir.delete(recursive: true);
  });

  test('clearAllData empties every table', () async {
    final db = await AppDatabase.instance.database;

    await db.insert('medications', {'id': 'm1', 'name': 'Tachipirina', 'quantity': 1});
    await db.insert('treatments', {'id': 't1', 'name': 'Fever', 'start_date': '2026-01-01'});
    await db.insert('prescriptions', {
      'id': 'p1',
      'treatment_id': 't1',
      'medication_id': 'm1',
      'dosage': '500mg',
      'start_time': '2026-01-01T08:00:00.000',
    });
    await db.insert('dose_logs', {
      'id': 'd1',
      'prescription_id': 'p1',
      'scheduled_time': '2026-01-01T08:00:00.000',
    });
    await db.insert('families', {'id': 'f1', 'name': 'The Family'});
    await db.insert('family_members', {'id': 'fm1', 'family_id': 'f1'});

    await AppDatabase.instance.clearAllData();

    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
      'families',
      'family_members',
    ]) {
      expect(await db.query(table), isEmpty, reason: table);
    }
  });
}
