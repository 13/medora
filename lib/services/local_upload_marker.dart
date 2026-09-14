/// Medora - Prepares local data for a fresh cloud account.
///
/// When the user turns cloud sync on, everything already on the device must
/// be uploaded: every synced row becomes pending_update and the pull cursors
/// are cleared so the first cycle is a full pull. Rows pending deletion are
/// left as they are.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/sync_cursor_store.dart';

class LocalUploadMarker {
  LocalUploadMarker({required AppDatabase database, required SyncCursorStore cursors})
      : _database = database,
        _cursors = cursors;

  final AppDatabase _database;
  final SyncCursorStore _cursors;

  static const tables = ['families', 'family_members', 'medications', 'treatments', 'prescriptions', 'dose_logs'];

  Future<int> markAllForUpload() async {
    final db = await _database.database;
    var count = 0;
    for (final table in tables) {
      count += await db.update(
        table,
        {'sync_status': SyncStatus.pendingUpdate},
        where: 'sync_status = ?',
        whereArgs: [SyncStatus.synced],
      );
    }
    await _cursors.clear();
    return count;
  }
}
