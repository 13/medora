/// Medora - Prepares local data for a cloud account, and remembers which
/// account the data on this device belongs to.
///
/// After a sign-in, everything already on the device has to be uploaded:
/// every synced row becomes pending_update and the pull cursors are cleared
/// so the first cycle is a full pull. Rows pending deletion are left alone.
///
/// Marking is deliberately *not* done when cloud mode is switched on, because
/// at that point nobody is signed in yet. A device that kept user A's data
/// ("turn off cloud → keep local data") would otherwise upload it into
/// whichever account signed in next. [ownerUserId] records whose data this is
/// so the sign-in flow can ask instead of guessing.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalUploadMarker {
  LocalUploadMarker({
    required this._database,
    required this._cursors,
    required this._prefs,
  });

  final AppDatabase _database;
  final SyncCursorStore _cursors;
  final SharedPreferences _prefs;

  /// Pref holding the id of the account the local rows belong to.
  static const ownerKey = 'sync.owner_user_id';

  static const tables = [
    'families',
    'family_members',
    'medications',
    'treatments',
    'prescriptions',
    'dose_logs',
  ];

  /// The account the data on this device was last uploaded under, if known.
  String? get ownerUserId => _prefs.getString(ownerKey);

  Future<void> setOwner(String userId) => _prefs.setString(ownerKey, userId);

  /// True when this device holds rows that were saved under a *different*
  /// account. Unknown ownership counts as "not foreign": data created before
  /// any sign-in belongs to whoever signs in first.
  Future<bool> hasDataFromAnotherAccount(String userId) async {
    final owner = ownerUserId;
    if (owner == null || owner == userId) return false;
    final db = await _database.database;
    for (final table in tables) {
      final rows = await db.query(table, columns: ['id'], limit: 1);
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  /// Flips every synced row to pending_update so the next cycle uploads it.
  ///
  /// [userId] is the signed-in account: only that user's own `family_members`
  /// row is marked. Other members' rows belong to them — re-uploading them
  /// would push rows this user has no business writing, and RLS rejects them
  /// anyway unless the user owns the family.
  ///
  /// The merge bases always go, so each row is merged against a fresh read
  /// of the server. The stock changes still waiting stay, unless the rows
  /// were last uploaded under another account ([ownerUserId]): offline doses
  /// of the same account must still reach its stock, and a cloud restore
  /// queues the restored counts before it calls this. The new account has
  /// none of the old one's medications, so each is created with its local
  /// quantity instead.
  ///
  /// Everything runs in one transaction: a kill half-way must not leave the
  /// bases gone and the rows still `synced`, which would never upload them.
  Future<int> markAllForUpload(String userId) async {
    final db = await _database.database;
    final owner = ownerUserId;
    final accountChanged = owner != null && owner != userId;
    final count = await db.transaction((txn) async {
      for (final table in const [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        await txn.update(table, const {
          'sync_version': null,
          'sync_base': null,
          'sync_write_id': null,
        });
      }
      if (accountChanged) await txn.delete('stock_outbox');
      var count = 0;
      for (final table in tables) {
        final ownRowOnly = table == 'family_members';
        count += await txn.update(
          table,
          {'sync_status': SyncStatus.pendingUpdate},
          where: ownRowOnly
              ? 'sync_status = ? AND user_id = ?'
              : 'sync_status = ?',
          whereArgs: ownRowOnly
              ? [SyncStatus.synced, userId]
              : [SyncStatus.synced],
        );
      }
      return count;
    });
    await _cursors.clear();
    return count;
  }
}
