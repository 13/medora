/// Medora - the stock and expiry alerts this device has already booked.
///
/// The dose scheduler can recover from an unknown state by cancelling every
/// pending dose reminder; this one deliberately cannot go that route for its
/// own ids, because it only ever cancels one at a time. Its snapshot
/// therefore has to outlive the process: an id that no run remembers is an
/// id no run can ever cancel, so a restocked or deleted medication would
/// keep announcing itself forever.
///
/// The stored value is versioned for exactly that reason. A shape this
/// version cannot read is not discarded — the *ids* are still recovered, with
/// [unknownFingerprint] standing in for "what it says is unknown", which
/// makes the next reconcile re-book the ones still wanted and cancel the
/// rest. Dropping the map would orphan every one of them permanently.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StockAlertStore {
  StockAlertStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store, for tests and for builds without preferences.
  StockAlertStore.inMemory() : _prefs = null;

  static const prefsKey = 'stock_alerts.scheduled';

  /// Schema version of the stored value.
  static const version = 1;

  /// Stands in for an alert whose booked content could not be read.
  ///
  /// It matches no real fingerprint, so the alert is cancelled and booked
  /// again rather than assumed to be up to date.
  static const unknownFingerprint = '?';

  final SharedPreferences? _prefs;
  Map<int, String> _memory = const {};

  /// Notification id → the fingerprint of the alert booked under it.
  Map<int, String> load() {
    final prefs = _prefs;
    if (prefs == null) return Map.of(_memory);
    final raw = prefs.getString(prefsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final storedVersion = decoded['v'];
      final alerts = storedVersion == version
          ? decoded['alerts'] as Map<String, dynamic>
          // Either the pre-version shape (id → millis) or one written by a
          // newer build. Both are unreadable here, but their keys are still
          // ids this device booked.
          : (decoded['alerts'] as Map<String, dynamic>?) ?? decoded;
      final readable = storedVersion == version;
      final restored = <int, String>{};
      for (final entry in alerts.entries) {
        final id = int.tryParse(entry.key);
        if (id == null) continue;
        final value = entry.value;
        // One malformed row costs only its own text, never the whole map.
        restored[id] = readable && value is String ? value : unknownFingerprint;
      }
      return restored;
    } catch (e) {
      debugPrint('Stock reminders: unreadable snapshot ($e), starting over');
      return {};
    }
  }

  Future<void> save(Map<int, String> scheduled) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memory = Map.of(scheduled);
      return;
    }
    if (scheduled.isEmpty) {
      await prefs.remove(prefsKey);
      return;
    }
    await prefs.setString(
      prefsKey,
      jsonEncode({
        'v': version,
        'alerts': {
          for (final entry in scheduled.entries) '${entry.key}': entry.value,
        },
      }),
    );
  }
}
