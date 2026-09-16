/// Medora - Stock and expiry reminder scheduler.
///
/// The second scheduler: it owns stock and expiry notifications only, while
/// [ReminderScheduler] owns the dose reminders. The two never disturb each
/// other because [stockAlertId] hands out ids in slots (offsets 8 and 9) that
/// dose reminders never take — which is also why this one never calls
/// `cancelAll()`. It cancels its own ids one by one, from the snapshot of the
/// previous run.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

class StockReminderScheduler {
  StockReminderScheduler({
    required this._port,
    required this._medications,
    required bool Function() stockRemindersEnabled,
    Now? now,
  }) : _enabled = stockRemindersEnabled,
       _now = now ?? systemNow;

  final ReminderPort _port;
  final MedicationRepository _medications;
  final bool Function() _enabled;
  final Now _now;

  /// The previous run's alerts: notification id → the time it fires.
  final Map<int, DateTime> _scheduled = {};

  /// Forget the snapshot, so the next [reconcile] schedules everything again.
  ///
  /// Re-scheduling reuses the same ids, so the notifications are replaced
  /// rather than duplicated — no cancel pass is needed first.
  void reset() => _scheduled.clear();

  /// Reconciles the scheduled alerts with the ones the cabinet now wants, and
  /// returns how many are scheduled.
  Future<int> reconcile() async {
    if (!_enabled()) {
      await _cancelAllKnown();
      return 0;
    }

    final result = await _medications.getMedications();
    final medications = result.when(
      success: (m) => m,
      failure: (message) {
        debugPrint('Stock reminders: could not load medications: $message');
        return null;
      },
    );
    // Keep the snapshot: a failed load must not look like "nothing is due"
    // and cancel every alert already scheduled.
    if (medications == null) return _scheduled.length;

    final desired = {
      for (final alert in stockAlertsFor(medications, _now())) alert.id: alert,
    };

    try {
      for (final id in _scheduled.keys.toList()) {
        // Gone, or moved to another time: the old notification must go.
        if (desired[id]?.when != _scheduled[id]) {
          await _port.cancelStockAlert(id);
        }
      }
      for (final alert in desired.values) {
        if (_scheduled[alert.id] != alert.when) {
          await _port.scheduleStockAlert(alert);
        }
      }
    } catch (e) {
      // Whatever landed before the failure stands; the snapshot is kept so
      // the next run still diffs against a state we actually reached.
      debugPrint('Stock reminders: the notification port failed: $e');
      return _scheduled.length;
    }

    _scheduled
      ..clear()
      ..addEntries(desired.values.map((a) => MapEntry(a.id, a.when)));
    debugPrint('Stock reminders: ${_scheduled.length} alert(s) scheduled');
    return _scheduled.length;
  }

  Future<void> _cancelAllKnown() async {
    for (final id in _scheduled.keys.toList()) {
      try {
        await _port.cancelStockAlert(id);
      } catch (e) {
        debugPrint('Stock reminders: could not cancel $id: $e');
      }
    }
    _scheduled.clear();
  }
}
