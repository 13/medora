/// Medora - Wipes everything the user created on this device.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalDataWiper {
  LocalDataWiper({
    required this._database,
    required this._photos,
    required this._reminders,
    required this._prefs,
  });

  final AppDatabase _database;
  final PhotoStorage _photos;
  final ReminderPort _reminders;
  final SharedPreferences _prefs;

  /// Removes user data: notifications, database rows, photo files.
  /// App preferences (theme, language, AIFA cache metadata) are kept.
  ///
  /// The database clear runs before photo cleanup so it is never blocked by
  /// a filesystem failure; on web (no local filesystem) photo cleanup is
  /// skipped entirely, and on other platforms a photo cleanup failure is
  /// logged rather than aborting the wipe.
  Future<void> wipe() async {
    await _reminders.cancelAll();
    await _database.clearAllData();
    if (!kIsWeb) {
      try {
        await _photos.deleteAll();
      } catch (e) {
        debugPrint('LocalDataWiper: photo cleanup failed: $e');
      }
    }
    await _prefs.reload();
    // Pull cursors and per-row push failures both describe rows that no
    // longer exist; leaving them behind would make the next sync skip a
    // fresh row it has never actually tried.
    for (final key
        in _prefs
            .getKeys()
            .where(
              (k) =>
                  k.startsWith(SyncCursorStore.keyPrefix) ||
                  k.startsWith(SyncCursorStore.pullKeyPrefix) ||
                  k.startsWith(SyncFailureStore.keyPrefix),
            )
            .toList()) {
      await _prefs.remove(key);
    }
    // No rows left, so this device no longer holds anyone's data.
    await _prefs.remove(LocalUploadMarker.ownerKey);
  }
}
