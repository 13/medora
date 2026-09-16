/// Medora - What a sync cycle does with a row it has just pushed.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:sqflite/sqflite.dart';

/// The server's `updated_at` from an upsert's `select('updated_at')` response,
/// or null when the response has none. The upserts ask for exactly one row
/// (`single()`), so a response that lacks the written row fails the push
/// instead of reaching here.
DateTime? serverStampOf(Map<String, dynamic>? response) {
  final raw = response?['updated_at'] as String?;
  return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

/// Settles the row [id] of [table] after the sync cycle pushed the copy whose
/// local `updated_at` was [pushedUpdatedAt]; [serverUpdatedAt] is the stamp
/// the server gave that write, when known. Returns true when the row still
/// has changes to push.
///
/// - **Unchanged since the push read it:** marked `synced`, and it takes the
///   server's stamp. That is the stamp every other device sees, and the next
///   local edit is stamped after it (`nextUpdatedAt`), so a device clock that
///   runs behind the server cannot make that edit look older than this push.
/// - **Edited while the push was in flight:** left pending, so the next cycle
///   sends the edit. The server now holds the older copy under a stamp that
///   can be later than the edit's; that stamp is this device's own write, so
///   the edit's stamp is raised just past it. Otherwise the cycle's pull, and
///   the next push's last-write-wins check, would count this device's own
///   older copy as newer than the edit and throw the edit away. The raise
///   is a floor, like `nextUpdatedAt`; it never skips anything.
/// - **Deleted while the push was in flight** (`pending_delete`; a delete
///   does not move `updated_at`) or gone: left alone.
///
/// Returns true for a pending delete too, since the delete is still to push.
Future<bool> settlePushedRow(
  Database db,
  String table, {
  required String id,
  required Object? pushedUpdatedAt,
  required DateTime? serverUpdatedAt,
}) {
  return db.transaction((txn) async {
    final rows = await txn.query(
      table,
      columns: ['updated_at', 'sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return false;
    final current = rows.first;
    if (current['sync_status'] == SyncStatus.pendingDelete) return true;
    final stamp = serverUpdatedAt?.toUtc().toIso8601String();
    if (current['updated_at'] == pushedUpdatedAt) {
      await txn.update(
        table,
        {'sync_status': SyncStatus.synced, 'updated_at': ?stamp},
        where: 'id = ?',
        whereArgs: [id],
      );
      return false;
    }
    // Changed and already synced again (a pull replaced it): nothing to do.
    if (current['sync_status'] == SyncStatus.synced) return false;
    if (serverUpdatedAt != null) {
      final raw = current['updated_at'] as String?;
      final edited = raw == null ? null : DateTime.tryParse(raw);
      final floored = nextUpdatedAt(serverUpdatedAt, edited ?? serverUpdatedAt);
      if (edited == null || !floored.isAtSameMomentAs(edited)) {
        await txn.update(
          table,
          {'updated_at': floored.toUtc().toIso8601String()},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
    return true;
  });
}
