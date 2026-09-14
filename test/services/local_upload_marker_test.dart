import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(tearDownTestDatabase);

  LocalUploadMarker makeMarker({SyncCursorStore? cursors}) => LocalUploadMarker(
    database: AppDatabase.instance,
    cursors: cursors ?? SyncCursorStore.inMemory(),
    prefs: prefs,
  );

  test('flips every synced row to pending_update and clears cursors', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final cursors = SyncCursorStore.inMemory();
    await cursors.setLastPullAt('medications', DateTime.utc(2026));

    final n = await makeMarker(cursors: cursors).markAllForUpload('user-a');

    expect(n, 4);
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      final rows = await db.query(table, columns: ['sync_status']);
      expect(
        rows.map((r) => r['sync_status']),
        everyElement(SyncStatus.pendingUpdate),
        reason: table,
      );
    }
    expect(await cursors.lastPullAt('medications'), isNull);
  });

  test('pending_delete rows are left alone', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await db.update(
      'medications',
      {'sync_status': SyncStatus.pendingDelete},
      where: 'id = ?',
      whereArgs: [seeded.medicationId],
    );
    await makeMarker().markAllForUpload('user-a');
    final row = (await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [seeded.medicationId],
    )).single;
    expect(row['sync_status'], SyncStatus.pendingDelete);
  });

  test('only the user\'s own family_members row is marked', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('families', {
      'id': 'f1',
      'name': 'S',
      'invite_code': 'X',
      'owner_id': 'user-a',
      'created_at': DateTime.utc(2026).toIso8601String(),
      'sync_status': SyncStatus.synced,
    });
    for (final (id, userId) in [('me', 'user-a'), ('them', 'user-b')]) {
      await db.insert('family_members', {
        'id': id,
        'family_id': 'f1',
        'user_id': userId,
        'display_name': id,
        'role': 'member',
        'joined_at': DateTime.utc(2026).toIso8601String(),
        'sync_status': SyncStatus.synced,
      });
    }

    await makeMarker().markAllForUpload('user-a');

    Future<Object?> status(String id) async => (await db.query(
      'family_members',
      columns: ['sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    )).single['sync_status'];
    expect(await status('me'), SyncStatus.pendingUpdate);
    expect(
      await status('them'),
      SyncStatus.synced,
      reason: 'another member\'s row is theirs to push, not ours',
    );
  });

  group('data owner', () {
    test('is null until recorded, then round-trips', () async {
      final marker = makeMarker();
      expect(marker.ownerUserId, isNull);
      await marker.setOwner('user-a');
      expect(marker.ownerUserId, 'user-a');
      expect(prefs.getString(LocalUploadMarker.ownerKey), 'user-a');
    });

    test(
      'unknown owner is not foreign data (first sign-in claims it)',
      () async {
        final db = await AppDatabase.instance.database;
        await seedPrescription(db);
        expect(await makeMarker().hasDataFromAnotherAccount('user-a'), isFalse);
      },
    );

    test('the same account signing back in is not foreign data', () async {
      final db = await AppDatabase.instance.database;
      await seedPrescription(db);
      final marker = makeMarker();
      await marker.setOwner('user-a');
      expect(await marker.hasDataFromAnotherAccount('user-a'), isFalse);
    });

    test('rows left by another account are foreign data', () async {
      final db = await AppDatabase.instance.database;
      await seedPrescription(db);
      final marker = makeMarker();
      await marker.setOwner('user-a');
      expect(await marker.hasDataFromAnotherAccount('user-b'), isTrue);
    });

    test(
      'another account with no rows left behind is not foreign data',
      () async {
        final marker = makeMarker();
        await marker.setOwner('user-a');
        expect(await marker.hasDataFromAnotherAccount('user-b'), isFalse);
      },
    );

    test('family rows alone are enough to count as foreign data', () async {
      final db = await AppDatabase.instance.database;
      await db.insert('families', {
        'id': 'f1',
        'name': 'S',
        'invite_code': 'X',
        'owner_id': 'user-a',
        'created_at': DateTime.utc(2026).toIso8601String(),
        'sync_status': SyncStatus.synced,
      });
      final marker = makeMarker();
      await marker.setOwner('user-a');
      expect(await marker.hasDataFromAnotherAccount('user-b'), isTrue);
    });
  });
}
