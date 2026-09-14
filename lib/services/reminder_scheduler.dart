/// Medora - Reminder scheduler.
///
/// Single owner of "which notifications exist". [reconcile] schedules
/// pending doses for the next [horizon], earliest first, capped at
/// [maxNotifications]. The first run (or the first after [reset]) cancels
/// everything and schedules the desired set; later runs diff against the
/// previous run's snapshot and only cancel/schedule the delta. When
/// reminders are disabled it cancels everything and schedules nothing.
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

  /// Ids scheduled by the previous run; null means "unknown, do a full cancel".
  Set<String>? _scheduledIds;

  void reset() => _scheduledIds = null;

  Future<int> _reconcileOnce() async {
    if (!_remindersEnabled()) {
      await _port.cancelAll();
      _scheduledIds = {};
      return 0;
    }
    final now = _now();
    final result = await _doses.getPendingDoseLogsBetween(now, now.add(horizon));
    final pending = result.when(success: (d) => d, failure: (msg) {
      debugPrint('Reminders: could not load pending doses: $msg');
      return null;
    });
    if (pending == null) return _scheduledIds?.length ?? 0;

    final limit = maxNotifications ~/ notificationsPerDose;
    final desired = pending.take(limit).toList();
    final desiredIds = desired.map((d) => d.id).toSet();
    final previous = _scheduledIds;

    if (previous == null) {
      await _port.cancelAll();
      for (final dose in desired) {
        await _port.scheduleForDose(dose: dose, medicationName: dose.medicationName ?? 'Medication');
      }
    } else {
      for (final id in previous.difference(desiredIds)) {
        await _port.cancelForDose(id);
      }
      for (final dose in desired.where((d) => !previous.contains(d.id))) {
        await _port.scheduleForDose(dose: dose, medicationName: dose.medicationName ?? 'Medication');
      }
    }
    _scheduledIds = desiredIds;
    debugPrint('Reminders: ${desiredIds.length} dose(s) scheduled (${pending.length} pending in horizon)');
    return desiredIds.length;
  }
}
