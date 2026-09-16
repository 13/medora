import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/migrations.dart';
import 'package:medora/services/backup_service.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

/// A 1x1 red PNG - small, but a real image with a valid header.
const _png = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, //
  0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84,
  120, 156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0,
  0, 73, 69, 78, 68, 174, 66, 96, 130,
];

void main() {
  late Directory root;
  late Directory outDir;
  late PhotoStorage photos;

  setUp(() async {
    await setUpTestDatabase();
    root = await Directory.systemTemp.createTemp('medora_backup_photos_');
    outDir = await Directory.systemTemp.createTemp('medora_backup_out_');
    photos = PhotoStorage(rootDirectory: () async => root);
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (root.existsSync()) await root.delete(recursive: true);
    if (outDir.existsSync()) await outDir.delete(recursive: true);
  });

  BackupService makeService({DateTime? now}) => BackupService(
    database: AppDatabase.instance,
    photos: photos,
    now: () => now ?? DateTime(2026, 3, 4, 17, 5),
    appVersion: '0.1.1+11',
  );

  /// Every row of every backed-up table, without the sync bookkeeping.
  Future<Map<String, List<Map<String, Object?>>>> snapshot(Database db) async {
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in BackupService.tables) {
      final rows = await db.query(table, orderBy: 'id');
      out[table] = [
        for (final row in rows)
          {
            for (final entry in row.entries)
              if (entry.key != 'sync_status') entry.key: entry.value,
          },
      ];
    }
    return out;
  }

  Future<void> seedEverything(Database db) async {
    await db.insert('families', {
      'id': 'fam-1',
      'name': 'Rossi',
      'invite_code': 'ABC123',
      'owner_id': 'user-a',
      'created_at': '2026-03-01T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });
    await db.insert('family_members', {
      'id': 'mem-1',
      'family_id': 'fam-1',
      'user_id': 'user-a',
      'display_name': 'Ben',
      'role': 'owner',
      'joined_at': '2026-03-01T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });
    final seeded = await seedPrescription(db);
    await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
  }

  test('export writes a timestamped envelope with row counts', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);

    final file = await makeService().exportToFile(outDir);

    expect(p.basename(file.path), 'medora-backup-20260304-170500.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['format'], 'medora-backup');
    expect(json['version'], 1);
    expect(json['schemaVersion'], kSchemaVersion);
    expect(json['appVersion'], '0.1.1+11');
    expect(DateTime.parse(json['createdAt']! as String).isUtc, isTrue);

    final tables = json['tables']! as Map<String, Object?>;
    expect(tables.keys, containsAll(BackupService.tables));
    expect((tables['medications']! as List).length, 1);
    expect((tables['dose_logs']! as List).length, 1);
    expect((tables['families']! as List).length, 1);
    expect(json['photos']! as Map, isEmpty);

    // Timestamps are exported exactly as stored, sync_status is dropped.
    final medication = (tables['medications']! as List).first as Map;
    expect(medication.containsKey('sync_status'), isFalse);
    final stored = (await db.query('medications')).single;
    expect(medication['created_at'], stored['created_at']);
  });

  test('inspect reports the manifest of an exported file', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    await photos.writeBytes('med_a.png', _png);

    final file = await makeService().exportToFile(outDir);
    final manifest = await makeService().inspect(file);

    expect(manifest.version, 1);
    expect(manifest.schemaVersion, kSchemaVersion);
    expect(manifest.appVersion, '0.1.1+11');
    expect(manifest.createdAt.isUtc, isTrue);
    expect(manifest.rowCounts['medications'], 1);
    expect(manifest.rowCounts['prescriptions'], 1);
    expect(manifest.totalRows, 6);
    expect(manifest.photoCount, 1);
  });

  test('restore replace rebuilds an emptied database row for row', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final before = await snapshot(db);

    final file = await makeService().exportToFile(outDir);
    await AppDatabase.instance.clearAllData();
    expect(await db.query('medications'), isEmpty);

    final manifest = await makeService().restore(
      file,
      mode: RestoreMode.replace,
    );

    expect(manifest.totalRows, 6);
    expect(await snapshot(db), before);
    final statuses = (await db.query(
      'medications',
      columns: ['sync_status'],
    )).map((r) => r['sync_status']).toSet();
    expect(statuses, {SyncStatus.synced});
  });

  test('a remembered pack EAN survives export and restore', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'med-ean',
      'name': 'Zinco-C',
      'quantity': 1,
      'minimum_stock_level': 0,
      'barcode': '107018',
      'ean': '8057737141836',
      'created_at': '2026-03-01T08:00:00.000',
      'updated_at': '2026-03-01T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });

    final file = await makeService().exportToFile(outDir);
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['schemaVersion'], 14);
    final exported =
        ((json['tables']! as Map)['medications']! as List).single as Map;
    expect(exported['ean'], '8057737141836');

    await AppDatabase.instance.clearAllData();
    await makeService().restore(file, mode: RestoreMode.replace);

    final restored = (await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: ['med-ean'],
    )).single;
    expect(restored['ean'], '8057737141836');
    expect(restored['barcode'], '107018');
  });

  test('restore replace drops rows that are not in the backup', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final file = await makeService().exportToFile(outDir);

    await db.insert('medications', {
      'id': 'later-med',
      'name': 'Aspirina',
      'quantity': 1,
      'minimum_stock_level': 0,
      'created_at': '2026-04-01T08:00:00.000',
      'updated_at': '2026-04-01T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });

    await makeService().restore(file, mode: RestoreMode.replace);

    expect(
      await db.query('medications', where: 'id = ?', whereArgs: ['later-med']),
      isEmpty,
    );
  });

  test('restore with markPending flags every restored row', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final file = await makeService().exportToFile(outDir);
    await AppDatabase.instance.clearAllData();

    await makeService().restore(
      file,
      mode: RestoreMode.replace,
      markPending: true,
    );

    final statuses = (await db.query(
      'medications',
      columns: ['sync_status'],
    )).map((r) => r['sync_status']).toSet();
    expect(statuses, {SyncStatus.pendingUpdate});
  });

  test('restore never marks family_members pending', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    // A second member: only the signed-in user may push their own row, so a
    // pending stamp here would be rejected by RLS on every cycle.
    await db.insert('family_members', {
      'id': 'mem-2',
      'family_id': 'fam-1',
      'user_id': 'user-b',
      'display_name': 'Ada',
      'role': 'member',
      'joined_at': '2026-03-02T08:00:00.000',
      'sync_status': SyncStatus.synced,
    });
    final file = await makeService().exportToFile(outDir);
    await AppDatabase.instance.clearAllData();

    await makeService().restore(
      file,
      mode: RestoreMode.replace,
      markPending: true,
    );

    final members = await db.query('family_members', columns: ['sync_status']);
    expect(members, hasLength(2));
    expect(
      members.map((r) => r['sync_status']).toSet(),
      {SyncStatus.synced},
      reason: 'family_members rows are left for LocalUploadMarker to pick',
    );
    for (final table in ['medications', 'treatments', 'prescriptions']) {
      final rows = await db.query(table, columns: ['sync_status']);
      expect(rows.map((r) => r['sync_status']).toSet(), {
        SyncStatus.pendingUpdate,
      }, reason: table);
    }
  });

  test('estimatePhotoBytes and countPhotos size the photo payload', () async {
    final service = makeService();
    expect(await service.estimatePhotoBytes(), 0);
    expect(await service.countPhotos(), 0);

    await photos.writeBytes('med_a.png', _png);
    await photos.writeBytes('med_b.png', _png);

    expect(await service.countPhotos(), 2);
    expect(await service.estimatePhotoBytes(), _png.length * 2);
  });

  test(
    'restore merge keeps the newer local row and adds missing ones',
    () async {
      final db = await AppDatabase.instance.database;
      await seedEverything(db);
      final medicationId =
          (await db.query('medications')).single['id']! as String;
      final file = await makeService().exportToFile(outDir);

      // The local row was edited after the backup was taken.
      await db.update(
        'medications',
        {'name': 'Edited locally', 'updated_at': '2099-01-01T09:00:00.000'},
        where: 'id = ?',
        whereArgs: [medicationId],
      );
      // ... and one row of the backup no longer exists locally.
      await db.delete('dose_logs');

      final manifest = await makeService().restore(
        file,
        mode: RestoreMode.merge,
      );

      expect(manifest.totalRows, 6);
      final medication = (await db.query('medications')).single;
      expect(medication['name'], 'Edited locally');
      expect(await db.query('dose_logs'), hasLength(1));
    },
  );

  test('restore merge overwrites a local row that is older', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final medicationId =
        (await db.query('medications')).single['id']! as String;
    await db.update(
      'medications',
      {'name': 'Backed up name', 'updated_at': '2099-01-01T09:00:00.000'},
      where: 'id = ?',
      whereArgs: [medicationId],
    );
    final file = await makeService().exportToFile(outDir);

    await db.update(
      'medications',
      {'name': 'Stale local name', 'updated_at': '2098-01-01T09:00:00.000'},
      where: 'id = ?',
      whereArgs: [medicationId],
    );

    await makeService().restore(file, mode: RestoreMode.merge);

    expect((await db.query('medications')).single['name'], 'Backed up name');
  });

  test('photos round-trip through the backup file', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    await photos.writeBytes('med_photo.png', _png);
    await db.update('medications', {'image_path': 'med_photo.png'});

    final file = await makeService().exportToFile(outDir);
    await photos.deleteAll();
    expect(await photos.resolve('med_photo.png'), isNull);
    await AppDatabase.instance.clearAllData();

    final manifest = await makeService().restore(
      file,
      mode: RestoreMode.replace,
    );

    expect(manifest.photoCount, 1);
    final restored = await photos.resolve('med_photo.png');
    expect(restored, isNotNull);
    expect(await restored!.readAsBytes(), _png);
    expect(
      (await db.query('medications')).single['image_path'],
      'med_photo.png',
    );
  });

  test('exportToFile can leave the photos out', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    await photos.writeBytes('med_photo.png', _png);

    final file = await makeService().exportToFile(outDir, includePhotos: false);

    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['photos'], isEmpty);
  });

  test('inspect rejects a file that is not a backup', () async {
    final file = File(p.join(outDir.path, 'garbage.json'))
      ..writeAsStringSync('not json at all');
    await expectLater(
      makeService().inspect(file),
      throwsA(
        isA<BackupException>().having(
          (e) => e.kind,
          'kind',
          BackupErrorKind.notABackup,
        ),
      ),
    );

    final wrongShape = File(p.join(outDir.path, 'other.json'))
      ..writeAsStringSync('{"format":"something-else","version":1}');
    await expectLater(
      makeService().inspect(wrongShape),
      throwsA(
        isA<BackupException>().having(
          (e) => e.kind,
          'kind',
          BackupErrorKind.notABackup,
        ),
      ),
    );
  });

  test('inspect reports a missing file as an I/O error', () async {
    await expectLater(
      makeService().inspect(File(p.join(outDir.path, 'absent.json'))),
      throwsA(
        isA<BackupException>().having(
          (e) => e.kind,
          'kind',
          BackupErrorKind.io,
        ),
      ),
    );
  });

  test('inspect refuses a newer format version', () async {
    final file = File(p.join(outDir.path, 'newer.json'))
      ..writeAsStringSync(
        jsonEncode({
          'format': 'medora-backup',
          'version': 2,
          'schemaVersion': kSchemaVersion,
          'createdAt': '2026-03-04T16:05:00.000Z',
          'appVersion': '9.9.9',
          'tables': <String, Object?>{},
          'photos': <String, Object?>{},
        }),
      );
    await expectLater(
      makeService().inspect(file),
      throwsA(
        isA<BackupException>().having(
          (e) => e.kind,
          'kind',
          BackupErrorKind.newerFormat,
        ),
      ),
    );
  });

  test('inspect refuses a newer schema version', () async {
    final file = File(p.join(outDir.path, 'newer_schema.json'))
      ..writeAsStringSync(
        jsonEncode({
          'format': 'medora-backup',
          'version': 1,
          'schemaVersion': kSchemaVersion + 1,
          'createdAt': '2026-03-04T16:05:00.000Z',
          'appVersion': '9.9.9',
          'tables': <String, Object?>{},
          'photos': <String, Object?>{},
        }),
      );
    await expectLater(
      makeService().inspect(file),
      throwsA(
        isA<BackupException>().having(
          (e) => e.kind,
          'kind',
          BackupErrorKind.newerSchema,
        ),
      ),
    );
  });

  test(
    'a backup with a broken reference leaves the database untouched',
    () async {
      final db = await AppDatabase.instance.database;
      await seedEverything(db);
      final before = await snapshot(db);

      final file = await makeService().exportToFile(outDir);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      (json['tables']! as Map<String, Object?>)['treatments'] = <Object?>[];
      await file.writeAsString(jsonEncode(json));

      await expectLater(
        makeService().restore(file, mode: RestoreMode.replace),
        throwsA(
          isA<BackupException>().having(
            (e) => e.kind,
            'kind',
            BackupErrorKind.corrupt,
          ),
        ),
      );

      expect(await snapshot(db), before);
    },
  );
}
