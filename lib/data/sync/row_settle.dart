/// Medora - What a sync cycle does with a row it has just pushed (sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite/sqflite.dart';

/// Settles the row [pushed] of [table] after the server answered [server]
/// for it (the row as written, or as fetched when it carries this device's
/// write id). Returns true when the row still has changes to push.
///
/// - **Unchanged since the push read it** (same local `updated_at`): the
///   server copy is stored as `synced` and becomes the base.
/// - **Edited while the push was in flight:** the server copy becomes the
///   base and the row stays `pending_update`, so the next push sends only
///   the newer difference. The columns it shares with the server copy take
///   the server's times.
/// - **Replaced by a pull meanwhile** (`synced` with another `updated_at`):
///   left as the pull stored it.
/// - **Deleted meanwhile** (`pending_delete`) or gone: left alone; a pending
///   delete returns true.
/// - **Stored deleted by the server** (a parent is deleted there): the row
///   goes here too; the delete wins.
Future<bool> settlePushedRow(
  Database db,
  String table, {
  required Map<String, Object?> pushed,
  required Map<String, dynamic> server,
  required String Function() newOpId,
}) {
  final id = pushed['id']! as String;
  final meta = RemoteMeta.fromJson(server);
  final base = canonicalWire(table, server);
  return db.transaction((txn) async {
    final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return false;
    final current = rows.first;
    if (meta.deletedAt != null) {
      await txn.delete(table, where: 'id = ?', whereArgs: [id]);
      return false;
    }
    final status = current['sync_status'] as String?;
    if (status == SyncStatus.pendingDelete) return true;
    if (current['updated_at'] == pushed['updated_at']) {
      final row = localRowOf(table, server, SyncStatus.synced);
      if (table == 'medications') {
        row['quantity'] = applyStockOps(
          (server['quantity'] as num?)?.toInt() ?? 0,
          await StockOutboxLocalDatasource.pendingIn(txn, medicationId: id),
        );
      }
      row.addAll(
        syncMetaValues(
          version: meta.rowVersion,
          base: base,
          baseTimes: meta.fieldTimes,
          editedAt: meta.effectiveEditedAt,
          fieldTimes: meta.fieldTimes,
        ),
      );
      if (table == 'dose_logs') row['delete_guard'] = null;
      await txn.update(table, row, where: 'id = ?', whereArgs: [id]);
      return false;
    }
    // Changed and synced again (a pull stored a server copy meanwhile): that
    // copy is newer than [server]; keep it.
    if (status == SyncStatus.synced) return false;
    await txn.update(
      table,
      {
        ...syncMetaValues(
          version: meta.rowVersion,
          base: base,
          baseTimes: meta.fieldTimes,
          fieldTimes: timesAgainstBase(
            localWire: localWire(table, current),
            localTimes: localFieldTimes(current),
            serverWire: base,
            serverTimes: meta.fieldTimes,
          ),
        ),
        'sync_status': SyncStatus.pendingUpdate,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return true;
  });
}
