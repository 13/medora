/// Medora - Stock changes on the server (`apply_stock_change`, sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum StockChangeStatus {
  /// Applied now.
  applied,

  /// This op id was applied before (a retry after a lost answer).
  duplicate,

  /// There is no live medication with this id for this user: it was
  /// deleted, removed from the server, or never reached it. The change can
  /// never apply: drop it. (A change is sent only once its medication's
  /// create reached the server, so this is never "not there yet".)
  gone,
}

/// A stock change brought into the range `apply_stock_change` accepts:
/// [setTo] into `0..maxStock`, [delta] into `-maxStock..maxStock`. The
/// server does the same, so a change out of range is never refused.
({int? delta, int? setTo}) stockChangeInRange({int? delta, int? setTo}) => (
  delta: delta?.clamp(-maxStock, maxStock),
  setTo: setTo?.clamp(0, maxStock),
);

/// The quantity `apply_stock_change` stores for a change to [quantity]:
/// the change is brought into range first ([stockChangeInRange]), then the
/// result is capped to `0..maxStock`.
int stockAfter(int quantity, {int? delta, int? setTo}) {
  final change = stockChangeInRange(delta: delta, setTo: setTo);
  return change.setTo ?? (quantity + change.delta!).clamp(0, maxStock);
}

class StockChangeResult {
  const StockChangeResult(this.status, {this.quantity, this.rowVersion});

  factory StockChangeResult.fromJson(Map<String, dynamic> json) =>
      StockChangeResult(
        StockChangeStatus.values.byName(json['status']! as String),
        quantity: (json['quantity'] as num?)?.toInt(),
        rowVersion: (json['row_version'] as num?)?.toInt(),
      );

  final StockChangeStatus status;

  /// The quantity right after the change ([StockChangeStatus.applied],
  /// [StockChangeStatus.duplicate]).
  final int? quantity;

  /// The medication's `row_version` after the change (applied only).
  final int? rowVersion;
}

abstract interface class StockRemote {
  Future<StockChangeResult> apply(StockOp op);
}

class PostgrestStockRemote implements StockRemote {
  PostgrestStockRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<StockChangeResult> apply(StockOp op) async {
    // In range before it leaves: a Dart int can exceed the function's
    // integer arguments, which the server would refuse on every retry.
    final change = stockChangeInRange(delta: op.delta, setTo: op.setTo);
    final raw = await _client.rpc<dynamic>(
      'apply_stock_change',
      params: {
        'p_op_id': op.opId,
        'p_medication_id': op.medicationId,
        'p_delta': change.delta,
        'p_set_to': change.setTo,
      },
    );
    return StockChangeResult.fromJson(raw as Map<String, dynamic>);
  }
}
