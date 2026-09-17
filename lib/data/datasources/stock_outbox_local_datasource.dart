/// Medora - Stock changes waiting to reach the server (sync v2).
///
/// A stock change is sent as a change, never as the new total: a delta (a
/// dose taken, a pack added, an undo) or a counted quantity typed into the
/// form. Each carries an id; the server applies an id once
/// (`apply_stock_change`), so a retry after a lost answer never counts it
/// twice, and changes from two devices both apply.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:sqflite/sqflite.dart';

/// One stock change: exactly one of [delta] and [setTo].
class StockOp {
  const StockOp({
    required this.opId,
    required this.medicationId,
    this.delta,
    this.setTo,
    required this.createdAt,
  }) : assert((delta == null) != (setTo == null), 'one kind per change');

  factory StockOp.fromRow(Map<String, Object?> row) => StockOp(
    opId: row['op_id']! as String,
    medicationId: row['medication_id']! as String,
    delta: row['delta'] as int?,
    setTo: row['set_to'] as int?,
    createdAt: DateTime.parse(row['created_at']! as String),
  );

  final String opId;
  final String medicationId;
  final int? delta;
  final int? setTo;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
    'op_id': opId,
    'medication_id': medicationId,
    'delta': delta,
    'set_to': setTo,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

/// The largest stock the app stores.
const maxStock = 999999;

/// [quantity] after [ops], in order, by the server's rule: each change is
/// brought into range before it applies (`stockAfter` in
/// `stock_remote.dart`), then the result is capped.
int applyStockOps(int quantity, Iterable<StockOp> ops) {
  var q = quantity;
  for (final op in ops) {
    final setTo = op.setTo;
    q = setTo != null
        ? setTo.clamp(0, maxStock)
        : (q + op.delta!.clamp(-maxStock, maxStock)).clamp(0, maxStock);
  }
  return q;
}

/// The stock this device shows for a server copy that holds [quantity] and
/// whose last write carried [writeId], with [ops] still waiting here: the
/// waiting changes on top. The oldest waiting change is left out when it is
/// the server copy's last write: `apply_stock_change` stamps its op id as
/// the write id, so that change already landed and only its answer was
/// lost. It stays in the outbox until the stock function answers for it.
int localStock(int quantity, String? writeId, List<StockOp> ops) =>
    applyStockOps(
      quantity,
      ops.isNotEmpty && ops.first.opId == writeId ? ops.skip(1) : ops,
    );

class StockOutboxLocalDatasource {
  StockOutboxLocalDatasource();

  static const table = 'stock_outbox';

  Future<Database> get _db => AppDatabase.instance.database;

  /// Adds [op] inside [txn], the transaction that changes the quantity.
  static Future<void> enqueue(DatabaseExecutor txn, StockOp op) =>
      txn.insert(table, op.toRow());

  /// The changes still waiting, in the order they were made; only
  /// [medicationId]'s when given.
  ///
  /// The order is the insertion order (`seq`), never `created_at`: two
  /// changes can share a millisecond, and the clock can step back between
  /// them. "Set to 10" then "−1" must replay as 9, not 10.
  Future<List<StockOp>> pending({String? medicationId}) async =>
      pendingIn(await _db, medicationId: medicationId);

  /// [pending] inside an open transaction.
  static Future<List<StockOp>> pendingIn(
    DatabaseExecutor db, {
    String? medicationId,
  }) async {
    final rows = await db.query(
      table,
      where: medicationId == null ? null : 'medication_id = ?',
      whereArgs: medicationId == null ? null : [medicationId],
      orderBy: 'seq',
    );
    return rows.map(StockOp.fromRow).toList();
  }

  /// Drops the change [opId]; true when it was there.
  Future<bool> remove(String opId) async =>
      await (await _db).delete(table, where: 'op_id = ?', whereArgs: [opId]) >
      0;

  Future<void> clearAll() async => (await _db).delete(table);
}
