import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/local/app_database.dart';

import '../helpers/test_database.dart';
import 'sync_service_test.dart' show Harness;

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<void> insertLocal(String table, Map<String, Object?> row) async =>
      (await AppDatabase.instance.database).insert(table, {
        'created_at': '2026-03-04T12:00:00.000Z',
        'updated_at': '2026-03-04T12:00:00.000Z',
        'edited_at': '2026-03-04T12:00:00.000Z',
        'sync_status': SyncStatus.pendingCreate,
        ...row,
      });

  test('a person, an rx and a dispensing made here reach the server', () async {
    final h = Harness();
    await insertLocal('persons', {
      'id': 'p1',
      'name': 'Ben',
      'exemptions': '[]',
    });
    await insertLocal('rx', {
      'id': 'r1',
      'person_id': 'p1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[{"id":"i1","description":"Brufen","packs":1}]',
      'cancelled': 0,
    });
    await insertLocal('rx_dispensings', {
      'id': 'd1',
      'rx_id': 'r1',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-03-02',
      'units_added': 0,
    });
    await h.service.syncAll();
    expect(h.rx.persons.get('p1')?['name'], 'Ben');
    expect(h.rx.rx.get('r1')?['person_id'], 'p1');
    expect(h.rx.dispensings.get('d1')?['rx_id'], 'r1');
  });

  test(
    'rows made on another device arrive here, dispensings after their rx',
    () async {
      final h = Harness();
      h.rx.dispensings.seed({
        'id': 'd9',
        'user_id': 'user-a',
        'rx_id': 'r9',
        'item_id': 'i1',
        'packs': 1,
        'dispensed_on': '2026-03-02',
        'units_added': 0,
      });
      h.rx.rx.seed({
        'id': 'r9',
        'user_id': 'user-a',
        'kind': 'white',
        'issued_on': '2026-03-01',
        'items': <Object?>[],
        'cancelled': false,
      });
      await h.service.syncAll();
      final db = await AppDatabase.instance.database;
      expect((await db.query('rx')).single['id'], 'r9');
      expect((await db.query('rx_dispensings')).single['id'], 'd9');
    },
  );

  test('discarding a stuck rx keeps the server copy and pulls its '
      'dispensings again', () async {
    final h = Harness();
    await insertLocal('rx', {
      'id': 'r1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[]',
      'cancelled': 0,
      'notes': 'server',
    });
    await h.service.syncAll();
    final db = await AppDatabase.instance.database;
    await db.update(
      'rx',
      {'notes': 'stuck', 'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: ['r1'],
    );
    await h.cursors.setPullKey('rx_dispensings', const PullKey(99));

    await h.service.discardFailedRow('rx', 'r1');

    final row = (await db.query('rx')).single;
    expect(row['notes'], 'server');
    expect(row['sync_status'], SyncStatus.synced);
    expect(await h.cursors.pullKey('rx_dispensings'), isNull);
  });

  test('deleting an rx here deletes its dispensings on the server', () async {
    final h = Harness();
    await insertLocal('rx', {
      'id': 'r1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[]',
      'cancelled': 0,
    });
    await insertLocal('rx_dispensings', {
      'id': 'd1',
      'rx_id': 'r1',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-03-02',
      'units_added': 0,
    });
    await h.service.syncAll();
    final db = await AppDatabase.instance.database;
    await db.update(
      'rx',
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': '2026-03-05T12:00:00.000Z',
        'edited_at': '2026-03-05T12:00:00.000Z',
      },
      where: 'id = ?',
      whereArgs: ['r1'],
    );
    await h.service.syncAll();
    expect(h.rx.rx.get('r1')?['deleted_at'], isNotNull);
    expect(h.rx.dispensings.get('d1')?['deleted_at'], isNotNull);
  });
}
