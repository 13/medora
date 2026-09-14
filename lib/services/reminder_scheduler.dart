/// Medora - Reminder scheduler.
///
/// Single owner of "which notifications exist". [reconcile] cancels
/// everything and re-schedules pending doses for the next [horizon],
/// earliest first, capped at [maxNotifications]. When reminders are
/// disabled it only cancels.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/reminder_port.dart';

class ReminderScheduler {
  ReminderScheduler({
    required ReminderPort port,
    required DoseLogRepository doses,
    required bool Function() remindersEnabled,
    DateTime Function()? now,
  })  : _port = port,
        _doses = doses,
        _remindersEnabled = remindersEnabled,
        _now = now ?? DateTime.now;

  static const horizon = Duration(days: 7);
  static const maxNotifications = 60; // iOS allows 64 pending
  static const notificationsPerDose = 2;

  final ReminderPort _port;
  final DoseLogRepository _doses;
  final bool Function() _remindersEnabled;
  final DateTime Function() _now;

  bool _running = false;
  bool _rerunRequested = false;

  /// Returns the number of doses that received notifications.
  ///
  /// If a reconcile is requested while one is already running, it is not
  /// dropped: the running reconcile reruns once more before returning.
  Future<int> reconcile() async {
    if (_running) {
      _rerunRequested = true;
      return 0;
    }
    _running = true;
    var scheduled = 0;
    try {
      do {
        _rerunRequested = false;
        scheduled = await _reconcileOnce();
      } while (_rerunRequested);
      return scheduled;
    } finally {
      _running = false;
    }
  }

  Future<int> _reconcileOnce() async {
    await _port.cancelAll();
    if (!_remindersEnabled()) return 0;

    final now = _now();
    final result = await _doses.getPendingDoseLogsBetween(now, now.add(horizon));
    return result.when(
      success: (pending) async {
        final limit = maxNotifications ~/ notificationsPerDose;

        var scheduled = 0;
        for (final dose in pending) {
          if (scheduled >= limit) break;
          await _port.scheduleForDose(
            dose: dose,
            medicationName: dose.medicationName ?? 'Medication',
          );
          scheduled++;
        }
        debugPrint('Reminders: scheduled $scheduled of ${pending.length} pending doses');
        return scheduled;
      },
      failure: (msg) async {
        debugPrint('Reminders: could not load pending doses: $msg');
        return 0;
      },
    );
  }
}
