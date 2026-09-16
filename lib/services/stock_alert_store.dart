/// Medora - the stock and expiry alerts this device has already booked.
///
/// The dose scheduler can recover from an unknown state by calling
/// `cancelAll()`; this one deliberately cannot, because that would take the
/// dose reminders with it. Its snapshot therefore has to outlive the process:
/// an id that no run remembers is an id no run can ever cancel, so a
/// restocked or deleted medication would keep announcing itself forever.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StockAlertStore {
  StockAlertStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store, for tests and for builds without preferences.
  StockAlertStore.inMemory() : _prefs = null;

  static const prefsKey = 'stock_alerts.scheduled';

  final SharedPreferences? _prefs;
  Map<int, DateTime> _memory = const {};

  /// Notification id → the time it fires, as last saved.
  Map<int, DateTime> load() {
    final prefs = _prefs;
    if (prefs == null) return Map.of(_memory);
    final raw = prefs.getString(prefsKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final restored = <int, DateTime>{};
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key);
        if (id == null) continue;
        restored[id] = DateTime.fromMillisecondsSinceEpoch(entry.value as int);
      }
      return restored;
    } catch (e) {
      // A snapshot that cannot be read is no worse than none: the ids are
      // derived from the medication, so the next run re-books the same ones.
      debugPrint('Stock reminders: unreadable snapshot ($e), starting over');
      return {};
    }
  }

  Future<void> save(Map<int, DateTime> scheduled) async {
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
        for (final entry in scheduled.entries)
          '${entry.key}': entry.value.millisecondsSinceEpoch,
      }),
    );
  }
}
