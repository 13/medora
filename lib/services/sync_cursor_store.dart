/// Medora - Per-table pull keys for delta sync (sync v2).
///
/// Stores, per table, where the next pull starts (`PullKey`: a transaction
/// id and a row id), so a pull asks only for rows written since.
///
/// It also keeps the markers of the one-time pull repair
/// ([startPullRepair]): builds before the paged pull read each table newest
/// first, and the server answers at most 1000 rows, so their cursors moved
/// past older rows that never arrived.
library;

import 'package:medora/data/datasources/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncCursorStore {
  SyncCursorStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncCursorStore.inMemory() : _prefs = null;

  /// The `updated_at` cursors of builds before sync v2. Still cleared by
  /// [clear], never written.
  static const keyPrefix = 'sync.last_pull_at.';

  /// The sync v2 pull keys (`PullKey.toStorage`).
  static const pullKeyPrefix = 'sync.pull_key.';

  /// The pull repair this build runs once per device. A later build that
  /// needs every table pulled in full once more raises it. Version 2 is the
  /// switch to sync v2: every table is pulled once from the start, so every
  /// row gets its merge base.
  static const pullRepairVersion = 2;

  /// The repair version whose cursor reset was applied. Outside [keyPrefix],
  /// so [clear] and a local data wipe keep it.
  static const pullRepairResetKey = 'sync.pull_repair.reset';

  /// The repair version whose full pull finished.
  static const pullRepairDoneKey = 'sync.pull_repair.done';

  /// The last "delete all data" generation this device applied, as
  /// `<user id>|<generation>`. Outside the cursor prefixes, so [clear]
  /// keeps it; a local data wipe removes it.
  static const wipeSeenKey = 'sync.wipe_seen';

  final SharedPreferences? _prefs;
  final Map<String, PullKey> _memoryKeys = {};
  String? _memoryWipeSeen;

  /// An in-memory store holds nothing an older build wrote, so it has
  /// nothing to repair.
  final Map<String, int> _memoryMarkers = {
    pullRepairResetKey: pullRepairVersion,
    pullRepairDoneKey: pullRepairVersion,
  };

  /// Where the next pull of [table] starts; null = from the beginning.
  Future<PullKey?> pullKey(String table) async {
    final prefs = _prefs;
    if (prefs == null) return _memoryKeys[table];
    return PullKey.fromStorage(prefs.getString('$pullKeyPrefix$table'));
  }

  Future<void> setPullKey(String table, PullKey key) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoryKeys[table] = key;
      return;
    }
    await prefs.setString('$pullKeyPrefix$table', key.toStorage());
  }

  /// Forgets [table]'s pull key: its next pull starts from the beginning.
  Future<void> resetPullKey(String table) async {
    _memoryKeys.remove(table);
    await _prefs?.remove('$pullKeyPrefix$table');
  }

  /// Forgets every cursor, old and new.
  Future<void> clear() async {
    _memoryKeys.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key
        in prefs
            .getKeys()
            .where(
              (k) => k.startsWith(keyPrefix) || k.startsWith(pullKeyPrefix),
            )
            .toList()) {
      await prefs.remove(key);
    }
  }

  /// The "delete all data" generation this device last applied for
  /// [userId]; null when it has none for that account (a fresh install, a
  /// wiped device, another account, or a build from before the marker).
  Future<int?> wipeSeen(String userId) async {
    final raw = _prefs?.getString(wipeSeenKey) ?? _memoryWipeSeen;
    if (raw == null) return null;
    final bar = raw.lastIndexOf('|');
    if (bar < 0 || raw.substring(0, bar) != userId) return null;
    return int.tryParse(raw.substring(bar + 1));
  }

  Future<void> setWipeSeen(String userId, int generation) async {
    final value = '$userId|$generation';
    final prefs = _prefs;
    if (prefs == null) {
      _memoryWipeSeen = value;
      return;
    }
    await prefs.setString(wipeSeenKey, value);
  }

  /// True when this device still holds a pull cursor of a build before
  /// sync v2 ([keyPrefix]): it synced under Medora 0.3.0 and has not run a
  /// 0.4.0 cycle since.
  bool get hasLegacyCursors =>
      _prefs?.getKeys().any((k) => k.startsWith(keyPrefix)) ?? false;

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
    if (prefs == null) return _memoryKeys.isNotEmpty;
    return prefs.getKeys().any(
      (k) => k.startsWith(keyPrefix) || k.startsWith(pullKeyPrefix),
    );
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
