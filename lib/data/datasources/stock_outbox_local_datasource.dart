/// Medora - Stock changes waiting to reach the server (sync v2).
///
/// A stock change is sent as a change, never as the new total: a delta (a
/// dose taken, a pack added, an undo) or a counted quantity typed into the
/// form. Each carries an id; the server applies an id once
/// (`apply_stock_change`), so a retry after a lost answer never counts it
/// twice, and changes from two devices both apply.
library;

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

/// [quantity] after [ops], in order, clamped like the server clamps.
int applyStockOps(int quantity, Iterable<StockOp> ops) {
  var q = quantity;
  for (final op in ops) {
    q = (op.setTo ?? q + op.delta!).clamp(0, maxStock);
  }
  return q;
}
