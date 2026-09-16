/// Medora - Per-table pull cursors for delta sync.
///
/// Stores the newest remote `updated_at` seen per table (minus a 1 s overlap,
/// applied by the caller) so the next pull can ask only for newer rows.
///
/// It also keeps the markers of the one-time pull repair
/// ([startPullRepair]): builds before the paged pull read each table newest
/// first, and the server answers at most 1000 rows, so their cursors moved
/// past older rows that never arrived.
library;

import 'package:shared_preferences/shared_preferences.dart';

class SyncCursorStore {
  SyncCursorStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncCursorStore.inMemory() : _prefs = null;

  static const keyPrefix = 'sync.last_pull_at.';

  /// The pull repair this build runs once per device. A later build that
  /// needs every table pulled in full once more raises it.
  static const pullRepairVersion = 1;

  /// The repair version whose cursor reset was applied. Outside [keyPrefix],
  /// so [clear] and a local data wipe keep it.
  static const pullRepairResetKey = 'sync.pull_repair.reset';

  /// The repair version whose full pull finished.
  static const pullRepairDoneKey = 'sync.pull_repair.done';

  final SharedPreferences? _prefs;
  final Map<String, DateTime> _memory = {};

  /// An in-memory store holds nothing an older build wrote, so it has
  /// nothing to repair.
  final Map<String, int> _memoryMarkers = {
    pullRepairResetKey: pullRepairVersion,
    pullRepairDoneKey: pullRepairVersion,
  };

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

  /// Called at the start of a sync cycle. True while the pull repair is not
  /// finished: the cycle's pull then counts as the repair pull, and the
  /// caller calls [finishPullRepair] once every table was fetched.
  ///
  /// The first time for this [pullRepairVersion] it clears every table's
  /// cursor, so the pull starts from the beginning and brings the rows an
  /// older build's cursor had moved past. It does so once only: a pull that
  /// fails part-way stores a cursor only for pages it stored in full, oldest
  /// first, so a retry goes on from there instead of from the start.
  ///
  /// A store with no cursor at all (a fresh install, or one whose data was
  /// wiped) has nothing to repair and is marked finished at once.
  Future<bool> startPullRepair() async {
    if (_marker(pullRepairDoneKey) >= pullRepairVersion) return false;
    if (_marker(pullRepairResetKey) < pullRepairVersion) {
      if (!_hasCursor()) {
        await finishPullRepair();
        return false;
      }
      await clear();
      await _setMarker(pullRepairResetKey, pullRepairVersion);
    }
    return true;
  }

  /// Records that the repair pull of this [pullRepairVersion] finished.
  Future<void> finishPullRepair() async {
    await _setMarker(pullRepairResetKey, pullRepairVersion);
    await _setMarker(pullRepairDoneKey, pullRepairVersion);
  }

  bool _hasCursor() {
    final prefs = _prefs;
    if (prefs == null) return _memory.isNotEmpty;
    return prefs.getKeys().any((k) => k.startsWith(keyPrefix));
  }

  int _marker(String key) {
    final prefs = _prefs;
    if (prefs == null) return _memoryMarkers[key] ?? 0;
    return prefs.getInt(key) ?? 0;
  }

  Future<void> _setMarker(String key, int version) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoryMarkers[key] = version;
      return;
    }
    await prefs.setInt(key, version);
  }
}
