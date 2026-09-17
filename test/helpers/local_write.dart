/// A local change written straight to a synced table, stamped the way the
/// app's own write paths stamp it: the columns it changes get [at] in
/// `field_edited_at` (see `fieldTimesAfterWrite`).
library;

import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Writes [values] to the row [id] of [table], stamping the columns they
/// change with [at] (1970: the app's own change).
Future<void> writeLocalChange(
  DatabaseExecutor db,
  String table,
  String id,
  Map<String, Object?> values, {
  required DateTime at,
}) async {
  final row = (await db.query(table, where: 'id = ?', whereArgs: [id])).single;
  await db.update(
    table,
    {
      ...values,
      'field_edited_at': fieldTimesAfterWrite(
        previous: row,
        after: {...row, ...values},
        wireOf: (r) => localWire(table, r),
        at: at,
      ),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}
