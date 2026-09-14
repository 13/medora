/// Medora - Wipes everything the user created on this device.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalDataWiper {
  LocalDataWiper({
    required AppDatabase database,
    required PhotoStorage photos,
    required ReminderPort reminders,
    required SharedPreferences prefs,
  })  : _database = database,
        _photos = photos,
        _reminders = reminders,
        _prefs = prefs;

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
  }
}
