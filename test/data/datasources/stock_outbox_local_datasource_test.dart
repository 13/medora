import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';

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
}
