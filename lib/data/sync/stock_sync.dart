/// Medora - Sending one stock change and settling it here (sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/sync_meta.dart';

/// Sends [op] through `apply_stock_change` and settles the answer. The
/// caller sends a change only once its medication has a known server
/// version, and in the order the changes were made.
///
/// - **applied:** the change leaves the outbox, and the stock here becomes
///   the server's plus the changes still waiting. When the server's version
///   is exactly one past the one this device holds, nothing else changed
///   the row in between: the base moves with it (its column times kept), so
///   this device's own stock change does not turn its next edit into a
///   conflict.
/// - **duplicate:** the server applied this change before (its answer was
///   lost). It leaves the outbox; the stock here already holds it, and the
///   pull brings the server's.
/// - **gone:** there is no live medication with this id for this user
///   (deleted, or removed from the server). The change can never apply, so
///   it leaves the outbox; the pull or the row push deals with the
///   medication.
///
/// A failed request, or an answer this app does not know, throws before
/// anything here changes: the change stays for a later cycle.
Future<StockChangeStatus> sendStockOp(StockRemote remote, StockOp op) async {
  final result = await remote.apply(op);
  final status = result.status;
  final db = await AppDatabase.instance.database;
  await db.transaction((txn) async {
    await txn.delete(
      StockOutboxLocalDatasource.table,
      where: 'op_id = ?',
      whereArgs: [op.opId],
    );
    final quantity = result.quantity;
    if (status != StockChangeStatus.applied || quantity == null) return;
    final rows = await txn.query(
      'medications',
      where: 'id = ?',
      whereArgs: [op.medicationId],
    );
    if (rows.isEmpty) return;
    final meta = LocalSyncMeta.fromRow(rows.first);
    final values = <String, Object?>{
      'quantity': applyStockOps(
        quantity,
        await StockOutboxLocalDatasource.pendingIn(
          txn,
          medicationId: op.medicationId,
        ),
      ),
    };
    final version = meta.version;
    final base = meta.base;
    final rowVersion = result.rowVersion;
    if (version != null &&
        base != null &&
        rowVersion != null &&
        rowVersion == version + 1) {
      values.addAll(
        syncMetaValues(
          version: rowVersion,
          base: {...base, 'quantity': quantity},
          baseTimes: meta.baseTimes,
          writeId: meta.writeId,
        ),
      );
    }
    await txn.update(
      'medications',
      values,
      where: 'id = ?',
      whereArgs: [op.medicationId],
    );
  });
  return status;
}
