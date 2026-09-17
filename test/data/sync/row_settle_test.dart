import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  const pushedAt = '2026-03-05T10:00:00.000';

  Map<String, dynamic> server({String name = 'Pushed', int quantity = 5}) => {
    'id': 'm1',
    'user_id': 'u',
    'name': name,
    'quantity': quantity,
    'row_version': 4,
    'sync_xid': 1200,
    'write_id': 'w1',
    'edited_at': '2026-03-05T10:00:00+00:00',
    'updated_at': '2026-03-05T10:00:01+00:00',
  };

  Future<Map<String, Object?>> seed(
    Database db, {
    String status = 'pending_update',
  }) async {
    await db.insert('medications', {
      'id': 'm1',
      'name': 'Pushed',
      'quantity': 5,
      'updated_at': pushedAt,
      'sync_status': status,
      'sync_write_id': 'w1',
    });
    return (await db.query('medications')).single;
  }

  Future<Map<String, Object?>> row(Database db) async =>
      (await db.query('medications')).single;

  test(
    'an unchanged row is synced and takes the server copy as its base',
    () async {
      final db = await AppDatabase.instance.database;
      final pushed = await seed(db);

      final pending = await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
      );

      expect(pending, isFalse);
      final r = await row(db);
      expect(r['sync_status'], 'synced');
      expect(r['sync_version'], 4);
      expect(r['sync_write_id'], isNull);
      expect(LocalSyncMeta.fromRow(r).base!['name'], 'Pushed');
      expect(r['updated_at'], isNot(pushedAt));
    },
  );

  test('a row edited meanwhile stays pending with the new base', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.update('medications', {
      'name': 'Edited meanwhile',
      'updated_at': '2026-03-05T10:00:00.500',
    });

    final pending = await settlePushedRow(
      db,
      'medications',
      pushed: pushed,
      server: server(),
    );

    expect(pending, isTrue);
    final r = await row(db);
    expect(r['sync_status'], 'pending_update');
    expect(r['name'], 'Edited meanwhile');
    expect(r['sync_version'], 4);
    expect(r['sync_write_id'], isNull);
  });

  test('a medication settles with the server\'s stock and the changes still '
      'waiting here on top', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    // A dose taken here while the push was on its way: the quantity and its
    // change, never the row's stamp.
    await db.transaction((txn) async {
      await txn.update('medications', {'quantity': 4});
      await StockOutboxLocalDatasource.enqueue(
        txn,
        StockOp(
          opId: 'taken',
          medicationId: 'm1',
          delta: -1,
          createdAt: DateTime.utc(2026, 3, 5, 10),
        ),
      );
    });

    final pending = await settlePushedRow(
      db,
      'medications',
      pushed: pushed,
      server: server(quantity: 7),
    );

    expect(pending, isFalse);
    final r = await row(db);
    expect([r['sync_status'], r['quantity']], ['synced', 6]);
    expect(LocalSyncMeta.fromRow(r).base!['quantity'], 7);
    expect(await StockOutboxLocalDatasource().pending(), hasLength(1));
  });

  test('a medication edited meanwhile keeps its own quantity', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.update('medications', {
      'name': 'Edited meanwhile',
      'quantity': 3,
      'updated_at': '2026-03-05T10:00:00.500',
    });

    await settlePushedRow(
      db,
      'medications',
      pushed: pushed,
      server: server(quantity: 7),
    );

    final r = await row(db);
    expect([r['sync_status'], r['quantity']], ['pending_update', 3]);
    expect(await StockOutboxLocalDatasource().pending(), isEmpty);
  });

  test('a delete made meanwhile stays a pending delete', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.update('medications', {'sync_status': 'pending_delete'});

    expect(
      await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
      ),
      isTrue,
    );
    expect((await row(db))['sync_status'], 'pending_delete');
  });

  test('a row a pull stored meanwhile is left as the pull stored it', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    // While the answer was on its way, a pull stored a newer server copy.
    await db.update('medications', {
      'name': 'Pulled',
      'updated_at': '2026-03-05T10:00:02.000Z',
      'sync_status': 'synced',
      'sync_version': 5,
      'sync_write_id': null,
    });

    final pending = await settlePushedRow(
      db,
      'medications',
      pushed: pushed,
      server: server(),
    );

    expect(pending, isFalse);
    final r = await row(db);
    expect(
      [r['sync_status'], r['sync_version'], r['name']],
      ['synced', 5, 'Pulled'],
    );
  });

  test('a row that is gone is nothing to push', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.delete('medications');

    expect(
      await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
      ),
      isFalse,
    );
  });
}
