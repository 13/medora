/// Medora - Per-row push-failure tracking for sync backoff.
///
/// A row that keeps failing to push (a permission error, a foreign key the
/// server rejects, a value the schema will never accept) otherwise poisons
/// every cycle: it fails again, the report stays `partial` forever, and for a
/// pull whose apply step depends on it the cursor never advances. This store
/// remembers how often each row has failed and when it was last tried, so the
/// push can leave it alone until an exponentially growing backoff has elapsed.
///
/// Keyed `table/id`, persisted in `SharedPreferences` (an in-memory variant
/// backs tests and builds without cloud sync).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// How often a row has failed in a row, and when it was last attempted.
class SyncRowFailure {
  const SyncRowFailure({required this.count, required this.lastAttempt});

  /// Consecutive failed push attempts; at least 1.
  final int count;
  final DateTime lastAttempt;

  /// Longest wait between two attempts.
  static const maxBackoff = Duration(hours: 6);

  /// `2^count` minutes, capped at [maxBackoff]: 2 min, 4, 8, … 6 h.
  Duration get backoff {
    // 2^count overflows nothing here, but the cap is reached at count == 9
    // (512 min > 6 h), so there is no point computing beyond that.
    if (count >= 9) return maxBackoff;
    final minutes = 1 << count;
    final d = Duration(minutes: minutes);
    return d > maxBackoff ? maxBackoff : d;
  }

  DateTime get nextAttemptAt => lastAttempt.add(backoff);

  /// True when [now] has not yet reached [nextAttemptAt].
  bool isBackingOffAt(DateTime now) => now.isBefore(nextAttemptAt);

  Map<String, dynamic> toJson() => {
    'count': count,
    'last_attempt': lastAttempt.toUtc().toIso8601String(),
  };

  static SyncRowFailure? fromJson(Map<String, dynamic> json) {
    final count = json['count'];
    final raw = json['last_attempt'];
    if (count is! int || raw is! String) return null;
    final at = DateTime.tryParse(raw);
    if (at == null) return null;
    return SyncRowFailure(count: count, lastAttempt: at.toUtc());
  }

  @override
  String toString() => 'SyncRowFailure(count: $count, at: $lastAttempt)';
}

class SyncFailureStore {
  SyncFailureStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncFailureStore.inMemory() : _prefs = null;

  static const keyPrefix = 'sync.failed_row.';

  final SharedPreferences? _prefs;
  final Map<String, SyncRowFailure> _memory = {};

  static String rowKey(String table, String id) => '$table/$id';

  Future<SyncRowFailure?> get(String table, String id) async {
    final key = rowKey(table, id);
    final prefs = _prefs;
    if (prefs == null) return _memory[key];
    final raw = prefs.getString('$keyPrefix$key');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return SyncRowFailure.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  /// Records one more consecutive failure for the row at [at]. Returns the
  /// stored record.
  Future<SyncRowFailure> recordFailure(
    String table,
    String id,
    DateTime at,
  ) async {
    final previous = await get(table, id);
    final record = SyncRowFailure(
      count: (previous?.count ?? 0) + 1,
      lastAttempt: at.toUtc(),
    );
    final key = rowKey(table, id);
    final prefs = _prefs;
    if (prefs == null) {
      _memory[key] = record;
    } else {
      await prefs.setString('$keyPrefix$key', jsonEncode(record.toJson()));
    }
    return record;
  }

  /// Forgets the row — called after a successful push, or when the user
  /// discards the local change.
  Future<void> clear(String table, String id) async {
    final key = rowKey(table, id);
    _memory.remove(key);
    await _prefs?.remove('$keyPrefix$key');
  }

  Future<void> clearAll() async {
    _memory.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(keyPrefix)).toList()) {
      await prefs.remove(key);
    }
  }
}
