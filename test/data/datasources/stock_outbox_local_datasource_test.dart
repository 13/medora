import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

StockOp _op(String id, {int? delta, int? setTo, int minute = 0}) => StockOp(
  opId: id,
  medicationId: 'm1',
  delta: delta,
  setTo: setTo,
  createdAt: DateTime.utc(2026, 3, 5, 8, minute),
);

void main() {
  group('applyStockOps', () {
    test('applies changes in order and clamps like the server', () {
      expect(applyStockOps(10, const []), 10);
      expect(applyStockOps(10, [_op('a', delta: -1), _op('b', delta: -1)]), 8);
      expect(applyStockOps(1, [_op('a', delta: -3)]), 0);
      expect(
        applyStockOps(10, [
          _op('a', delta: -1),
          _op('b', setTo: 20),
          _op('c', delta: -2),
        ]),
        18,
      );
      expect(applyStockOps(999998, [_op('a', delta: 5)]), maxStock);
    });

    test('brings a change into range before adding it, as the server does', () {
      // The largest int would wrap past the top if it were added first.
      const huge = 0x7fffffffffffffff;
      expect(applyStockOps(maxStock, [_op('a', delta: huge)]), maxStock);
      expect(applyStockOps(5, [_op('a', delta: -huge)]), 0);
      expect(applyStockOps(5, [_op('a', setTo: huge)]), maxStock);
      expect(applyStockOps(5, [_op('a', setTo: -3)]), 0);
      // Always the same result as the server's rule.
      for (final (q, delta) in [(0, huge), (maxStock, -huge), (7, 3)]) {
        expect(
          applyStockOps(q, [_op('a', delta: delta)]),
          stockAfter(q, delta: delta),
        );
      }
    });

    test('a change is a delta or a count, never both', () {
      expect(
        () => _op('x', delta: 1, setTo: 1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a change round-trips through its row', () {
      final op = _op('a', delta: -2, minute: 7);
      final back = StockOp.fromRow(op.toRow());
      expect(
        [back.opId, back.medicationId, back.delta, back.setTo, back.createdAt],
        ['a', 'm1', -2, null, DateTime.utc(2026, 3, 5, 8, 7)],
      );
    });
  });

  group('StockOutboxLocalDatasource', () {
    setUp(() async {
      await setUpTestDatabase();
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {'id': 'm1', 'name': 'M', 'quantity': 5});
      await db.insert('medications', {'id': 'm2', 'name': 'N', 'quantity': 5});
    });
    tearDown(tearDownTestDatabase);

    test('keeps changes in the order they were made, per medication, until '
        'removed', () async {
      final db = await AppDatabase.instance.database;
      await db.transaction((txn) async {
        await StockOutboxLocalDatasource.enqueue(
          txn,
          _op('late', delta: -1, minute: 9),
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          _op('early', delta: -1, minute: 1),
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          StockOp(
            opId: 'other',
            medicationId: 'm2',
            setTo: 3,
            createdAt: DateTime.utc(2026, 3, 5, 8, 5),
          ),
        );
      });
      final outbox = StockOutboxLocalDatasource();
      // The order they were made in, whatever their clock times say.
      expect((await outbox.pending()).map((o) => o.opId), [
        'late',
        'early',
        'other',
      ]);
      expect((await outbox.pending(medicationId: 'm1')).map((o) => o.opId), [
        'late',
        'early',
      ]);
      expect(await outbox.remove('late'), isTrue);
      expect(await outbox.remove('late'), isFalse);
      expect((await outbox.pending()).map((o) => o.opId), ['early', 'other']);
      await outbox.clearAll();
      expect(await outbox.pending(), isEmpty);
    });

    Future<int> replay(List<StockOp> ops) async {
      final db = await AppDatabase.instance.database;
      for (final op in ops) {
        await StockOutboxLocalDatasource.enqueue(db, op);
      }
      return applyStockOps(5, await StockOutboxLocalDatasource().pending());
    }

    test('a count and a change made in the same millisecond replay in the '
        'order they were made', () async {
      // Op ids are random: here the later change sorts first.
      expect(
        await replay([
          _op('zzz', setTo: 10, minute: 3),
          _op('aaa', delta: -1, minute: 3),
        ]),
        9,
      );
    });

    test('a change made after the clock stepped back still replays '
        'last', () async {
      expect(
        await replay([
          _op('first', setTo: 10, minute: 9),
          _op('second', delta: -1, minute: 1),
        ]),
        9,
      );
    });

    test('an op id is applied once: a second enqueue of it fails', () async {
      final db = await AppDatabase.instance.database;
      await StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1));
      await expectLater(
        StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1)),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('the order survives a removal of the newest change', () async {
      final db = await AppDatabase.instance.database;
      final outbox = StockOutboxLocalDatasource();
      await StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1));
      await StockOutboxLocalDatasource.enqueue(db, _op('b', delta: -1));
      await outbox.remove('b');
      await StockOutboxLocalDatasource.enqueue(db, _op('c', delta: -1));
      await outbox.remove('a');
      await StockOutboxLocalDatasource.enqueue(db, _op('d', setTo: 1));
      expect((await outbox.pending()).map((o) => o.opId), ['c', 'd']);
    });

    test('a medication deleted here takes its changes with it', () async {
      final db = await AppDatabase.instance.database;
      await StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1));
      await db.delete('medications', where: 'id = ?', whereArgs: ['m1']);
      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
    });
  });
}
