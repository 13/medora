import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/remote_wipe.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final wipedAt = DateTime.utc(2026, 3, 5, 10);
  String before([int minutes = 1]) =>
      wipedAt.subtract(Duration(minutes: minutes)).toIso8601String();
  String after([int minutes = 1]) =>
      wipedAt.add(Duration(minutes: minutes)).toIso8601String();

  Future<List<String>> ids(String table) async => [
    for (final r in await (await AppDatabase.instance.database).query(
      table,
      orderBy: 'id',
    ))
      r['id']! as String,
  ];

  test('rows made before the wipe go in any sync state, with their '
      'children and stock changes; rows made after it stay', () async {
    final db = await AppDatabase.instance.database;
    final old = await seedPrescription(db);
    await db.update('medications', {
      'created_at': before(60),
      'image_path': 'old.jpg',
    });
    await db.update('treatments', {'created_at': before(60)});
    await db.update('prescriptions', {'created_at': before(60)});
    await db.insert('dose_logs', {
      'id': 'd-old',
      'prescription_id': old.prescriptionId,
      'scheduled_time': before(),
      'status': 'taken',
      'created_at': before(30),
      'updated_at': after(),
      'sync_status': 'pending_update',
    });
    await db.insert('stock_outbox', {
      'op_id': 'op-old',
      'medication_id': old.medicationId,
      'delta': -1,
      'created_at': after(),
    });
    // Made after the wipe: a medication (a photo shared with the old one),
    // one without a creation time (counts as older), and one whose time is
    // naive wall-clock text in this zone.
    await db.insert('medications', {
      'id': 'm-new',
      'name': 'New',
      'image_path': 'old.jpg',
      'created_at': after(5),
      'sync_status': 'pending_create',
    });
    await db.insert('medications', {
      'id': 'm-unknown',
      'name': 'Unknown',
      'image_path': 'unknown.jpg',
      'sync_status': 'synced',
    });
    await db.insert('medications', {
      'id': 'm-local-text',
      'name': 'Local',
      'created_at': wipedAt
          .add(const Duration(minutes: 2))
          .toLocal()
          .toIso8601String(),
      'sync_status': 'pending_create',
    });
    await db.insert('families', {
      'id': 'f1',
      'name': 'Home',
      'invite_code': 'X',
      'owner_id': 'u',
      'sync_status': 'synced',
    });

    final removed = await removeLocalDataFromBefore(wipedAt);

    expect(await ids('medications'), ['m-local-text', 'm-new']);
    expect(await ids('treatments'), isEmpty);
    expect(await ids('prescriptions'), isEmpty);
    expect(await ids('dose_logs'), isEmpty);
    expect(await db.query('stock_outbox'), isEmpty);
    expect(await ids('families'), ['f1']);
    // Two medications, the treatment, the prescription and the dose.
    expect(removed.rows, 5);
    expect(removed.photos, ['unknown.jpg'], reason: 'old.jpg is still used');
  });

  test('nothing to remove', () async {
    final removed = await removeLocalDataFromBefore(wipedAt);
    expect(removed.rows, 0);
    expect(removed.photos, isEmpty);
  });
}
