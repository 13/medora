import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/stock_sync.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/test_database.dart';

/// A stock remote that answers what the test says, without a server.
class _Answering implements StockRemote {
  _Answering(this.answer);
  final Future<StockChangeResult> Function(StockOp op) answer;

  @override
  Future<StockChangeResult> apply(StockOp op) => answer(op);
}

void main() {
  late FakeServerCore core;
  late FakeStockRemote stock;
  late TableSync meds;

  Future<void> pullAll() async {
    for (final row in core.page('medications', horizon: core.horizon)) {
      await meds.applyPulled(row);
    }
  }

  setUp(() async {
    await setUpTestDatabase();
    core = FakeServerCore(() => DateTime.utc(2026, 3, 5, 12));
    stock = FakeStockRemote(core);
    meds = TableSync(
      table: 'medications',
      remote: FakeSyncTable(core, 'medications'),
      newWriteId: () => 'w',
      now: () => DateTime.utc(2026, 3, 5, 12),
    );
    // A medication a 0.3.0 device made, with 10 in stock, pulled here.
    core.legacyUpsert('medications', {
      'id': 'm1',
      'user_id': 'u',
      'name': 'Ibu',
      'quantity': 10,
    });
    await pullAll();
  });
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> localMed() async =>
      (await (await AppDatabase.instance.database).query(
        'medications',
        where: "id = 'm1'",
      )).single;

  Future<int> localQuantity() async => (await localMed())['quantity']! as int;

  /// One tablet taken here: the quantity and its change, in one transaction.
  Future<void> take(String opId, {int delta = -1}) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.rawUpdate(
        "UPDATE medications SET quantity = quantity + ? WHERE id = 'm1'",
        [delta],
      );
      await StockOutboxLocalDatasource.enqueue(
        txn,
        StockOp(
          opId: opId,
          medicationId: 'm1',
          delta: delta,
          createdAt: DateTime.utc(2026, 3, 5, 11),
        ),
      );
    });
  }

  Future<List<String>> waiting() async => [
    for (final op in await StockOutboxLocalDatasource().pending()) op.opId,
  ];

  test('two devices each take one: 10 -> 8 on both', () async {
    await take('b1');
    expect(await localQuantity(), 9);
    // The other device's change lands first.
    core.applyStockChange(opId: 'a1', medicationId: 'm1', delta: -1);

    for (final op in await StockOutboxLocalDatasource().pending()) {
      expect(await sendStockOp(stock, op), StockChangeStatus.applied);
    }

    expect(core.rowsOf('medications')['m1']!['quantity'], 8);
    expect(await localQuantity(), 8);
    expect(await waiting(), isEmpty);
  });

  test('a lost answer is not counted twice', () async {
    await take('b1');
    stock.loseNextAnswers = 1;
    final op = (await StockOutboxLocalDatasource().pending()).single;

    await expectLater(sendStockOp(stock, op), throwsA(isA<TimeoutException>()));
    expect(await waiting(), ['b1']);
    expect(await sendStockOp(stock, op), StockChangeStatus.duplicate);

    expect(core.rowsOf('medications')['m1']!['quantity'], 9);
    expect(core.ledger.keys, ['b1']);
    expect(await waiting(), isEmpty);
    // The duplicate's answer leaves the local quantity alone: it already
    // holds the change, and the pull brings the server's.
    expect(await localQuantity(), 9);
  });

  test('a change that never reached the server stays for the next cycle, '
      'in its place', () async {
    await take('b1');
    await take('b2');
    stock.failNextRequests = 1;
    final ops = await StockOutboxLocalDatasource().pending();

    await expectLater(sendStockOp(stock, ops.first), throwsA(isA<Object>()));
    expect(core.ledger, isEmpty);
    expect(await waiting(), ['b1', 'b2']);
    expect(await localQuantity(), 8);
  });

  test('a pull while a change waits keeps it on top', () async {
    await take('b1');
    core.applyStockChange(opId: 'a1', medicationId: 'm1', delta: -3);

    await pullAll();

    expect(await localQuantity(), 6);
    expect(await waiting(), ['b1']);
  });

  test(
    'own stock change moves the base: the next edit is no conflict',
    () async {
      await take('b1');
      await sendStockOp(
        stock,
        (await StockOutboxLocalDatasource().pending()).single,
      );
      final db = await AppDatabase.instance.database;
      final row = await localMed();
      expect(row['sync_version'], 2);
      expect(LocalSyncMeta.fromRow(row).base!['quantity'], 9);
      await db.update('medications', {
        'name': 'Ibuprofen',
        'sync_status': 'pending_update',
        'edited_at': '2026-03-05T11:59:00.000Z',
      }, where: "id = 'm1'");
      final before = core.requests.length;

      await meds.pushRow(await localMed(), userId: 'u');

      expect(core.requests.sublist(before), ['medications:patch']);
      expect(core.rowsOf('medications')['m1']!['name'], 'Ibuprofen');
      expect(core.rowsOf('medications')['m1']!['quantity'], 9);
    },
  );

  test('moving the base keeps the base\'s column times', () async {
    final db = await AppDatabase.instance.database;
    final times = LocalSyncMeta.fromRow(await localMed()).baseTimes;
    expect(times, isNotNull);
    await take('b1');

    await sendStockOp(
      stock,
      (await StockOutboxLocalDatasource().pending()).single,
    );

    final moved = LocalSyncMeta.fromRow(await localMed());
    expect(moved.version, 2);
    expect(moved.baseTimes, isNotNull);
    expect(jsonEncode(moved.baseTimes!.toJson()), jsonEncode(times!.toJson()));
    expect((await db.query('medications')).single['sync_write_id'], isNull);
  });

  test('another change on the server in between leaves the base where it '
      'was', () async {
    await take('b1');
    await take('b2');
    // Another device renamed it: the server is one version further on.
    core.patch('medications', 'm1', {
      'name': 'Ibuprofen',
      'write_id': 'other',
      'edited_at': '2026-03-05T11:00:00Z',
    });

    expect(
      await sendStockOp(
        stock,
        (await StockOutboxLocalDatasource().pending()).first,
      ),
      StockChangeStatus.applied,
    );

    final row = await localMed();
    expect(row['sync_version'], 1);
    expect(LocalSyncMeta.fromRow(row).base!['name'], 'Ibu');
    // The server's 9, with the change still waiting on top.
    expect(row['quantity'], 8);
    expect(await waiting(), ['b2']);

    // The pull brings the rename, and the waiting change stays on top.
    await pullAll();
    final pulled = await localMed();
    expect([pulled['name'], pulled['quantity']], ['Ibuprofen', 8]);
  });

  test('a medication gone from the server drops the change for good', () async {
    await take('b1');
    core.purge('medications', 'm1');

    final op = (await StockOutboxLocalDatasource().pending()).single;
    expect(await sendStockOp(stock, op), StockChangeStatus.gone);

    expect(await waiting(), isEmpty);
    expect(core.ledger, isEmpty);
    // The local copy is left to the pull and the row push.
    expect(await localQuantity(), 9);
  });

  test('a medication deleted on the server drops the change', () async {
    await take('b1');
    core.patch('medications', 'm1', {
      'deleted_at': '2026-03-05T11:30:00Z',
      'write_id': 'other',
      'edited_at': '2026-03-05T11:30:00Z',
    });

    final op = (await StockOutboxLocalDatasource().pending()).single;
    expect(await sendStockOp(stock, op), StockChangeStatus.gone);
    expect(await waiting(), isEmpty);
  });

  test('an answer it cannot read keeps the change', () async {
    await take('b1');
    final op = (await StockOutboxLocalDatasource().pending()).single;
    final remote = _Answering(
      (_) async => StockChangeResult.fromJson({'status': 'missing'}),
    );

    await expectLater(sendStockOp(remote, op), throwsA(isA<ArgumentError>()));
    expect(await waiting(), ['b1']);
    expect(await localQuantity(), 9);
  });

  test('an applied change for a medication no longer here only leaves the '
      'outbox', () async {
    final op = StockOp(
      opId: 'x1',
      medicationId: 'elsewhere',
      delta: -1,
      createdAt: DateTime.utc(2026, 3, 5, 11),
    );
    final remote = _Answering(
      (_) async => const StockChangeResult(
        StockChangeStatus.applied,
        quantity: 4,
        rowVersion: 3,
      ),
    );

    expect(await sendStockOp(remote, op), StockChangeStatus.applied);
    expect(await localQuantity(), 10);
  });
}
