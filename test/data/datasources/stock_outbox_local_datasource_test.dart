import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';

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

    test('keeps changes oldest first, per medication, until removed', () async {
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
      expect((await outbox.pending()).map((o) => o.opId), [
        'early',
        'other',
        'late',
      ]);
      expect((await outbox.pending(medicationId: 'm1')).map((o) => o.opId), [
        'early',
        'late',
      ]);
      expect(await outbox.remove('early'), isTrue);
      expect(await outbox.remove('early'), isFalse);
      expect((await outbox.pending()).map((o) => o.opId), ['other', 'late']);
      await outbox.clearAll();
      expect(await outbox.pending(), isEmpty);
    });

    test('a medication deleted here takes its changes with it', () async {
      final db = await AppDatabase.instance.database;
      await StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1));
      await db.delete('medications', where: 'id = ?', whereArgs: ['m1']);
      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
    });
  });
}
