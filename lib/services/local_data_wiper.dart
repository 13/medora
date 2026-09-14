/// Medora - Wipes everything the user created on this device.
library;

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

  /// Removes user data: notifications, photos, database rows.
  /// App preferences (theme, language, AIFA cache metadata) are kept.
  Future<void> wipe() async {
    await _reminders.cancelAll();
    await _photos.deleteAll();
    await _database.clearAllData();
    // No per-user prefs exist yet; keep this hook for future keys.
    await _prefs.reload();
  }
}
