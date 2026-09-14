/// Medora - Per-table pull cursors for delta sync.
///
/// Stores the newest remote `updated_at` seen per table (minus a 1 s overlap,
/// applied by the caller) so the next pull can ask only for newer rows.
library;

import 'package:shared_preferences/shared_preferences.dart';

class SyncCursorStore {
  SyncCursorStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncCursorStore.inMemory() : _prefs = null;

  static const keyPrefix = 'sync.last_pull_at.';

  final SharedPreferences? _prefs;
  final Map<String, DateTime> _memory = {};

  Future<DateTime?> lastPullAt(String table) async {
    final prefs = _prefs;
    if (prefs == null) return _memory[table];
    final raw = prefs.getString('$keyPrefix$table');
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setLastPullAt(String table, DateTime at) async {
    final utc = at.toUtc();
    final prefs = _prefs;
    if (prefs == null) {
      _memory[table] = utc;
      return;
    }
    await prefs.setString('$keyPrefix$table', utc.toIso8601String());
  }

  Future<void> clear() async {
    _memory.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(keyPrefix)).toList()) {
      await prefs.remove(key);
    }
  }
}
