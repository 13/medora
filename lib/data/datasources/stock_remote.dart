/// Medora - Stock changes on the server (`apply_stock_change`, sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum StockChangeStatus {
  /// Applied now.
  applied,

  /// This op id was applied before (a retry after a lost answer).
  duplicate,

  /// The medication is deleted: drop the change.
  gone,

  /// No such medication on the server yet: keep the change.
  missing,
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
    final raw = await _client.rpc<dynamic>(
      'apply_stock_change',
      params: {
        'p_op_id': op.opId,
        'p_medication_id': op.medicationId,
        'p_delta': op.delta,
        'p_set_to': op.setTo,
      },
    );
    return StockChangeResult.fromJson(raw as Map<String, dynamic>);
  }
}
