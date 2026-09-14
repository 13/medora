/// Medora - Reminder scheduler.
///
/// Single owner of "which notifications exist". [reconcile] schedules
/// pending doses for the next [horizon], earliest first, capped at
/// [maxNotifications]. The first run (or the first after [reset]) cancels
/// everything and schedules the desired set; later runs diff against the
/// previous run's snapshot and only cancel/schedule the delta. The snapshot
/// tracks id and scheduled time; a dose whose time changes (e.g. after a
/// cloud pull) is re-scheduled. When reminders are disabled it cancels
/// everything and schedules nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/reminder_port.dart';

class ReminderScheduler {
  ReminderScheduler({
    required this._port,
    required this._doses,
    required this._remindersEnabled,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const horizon = Duration(days: 7);
  static const maxNotifications = 60; // iOS allows 64 pending
  static const notificationsPerDose = 2;

  final ReminderPort _port;
  final DoseLogRepository _doses;
  final bool Function() _remindersEnabled;
  final DateTime Function() _now;

  bool _running = false;
  bool _rerunRequested = false;

  /// The error from the most recent reconcile attempt, or null when the
  /// last attempt succeeded. A failed attempt keeps the previous snapshot
  /// and notification set untouched — this is purely for callers that want
  /// to surface "reminders may be out of date" somewhere.
  Object? get lastError => _lastError;
  Object? _lastError;

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

  /// Snapshot of the previous run: dose id → scheduled time. Null means
  /// "unknown, do a full cancel".
  Map<String, DateTime>? _scheduled;

  void reset() => _scheduled = null;

  Future<int> _reconcileOnce() async {
    if (!_remindersEnabled()) {
      await _port.cancelAll();
      _scheduled = {};
      _lastError = null;
      return 0;
    }
    final now = _now();
    final result = await _doses.getPendingDoseLogsBetween(
      now,
      now.add(horizon),
    );
    final pending = result.when(
      success: (d) => d,
      failure: (msg) {
        debugPrint('Reminders: could not load pending doses: $msg');
        return null;
      },
    );
    if (pending == null) {
      _lastError = StateError('could not load pending doses');
      return _scheduled?.length ?? 0;
    }

    const limit = maxNotifications ~/ notificationsPerDose;
    final desired = pending.take(limit).toList();
    final desiredMap = {for (final d in desired) d.id: d.scheduledTime};
    final previous = _scheduled;

    try {
      if (previous == null) {
        await _port.cancelAll();
        for (final dose in desired) {
          await _port.scheduleForDose(
            dose: dose,
            medicationName: dose.medicationName ?? 'Medication',
          );
        }
      } else {
        for (final id in previous.keys) {
          if (!desiredMap.containsKey(id) || desiredMap[id] != previous[id]) {
            await _port.cancelForDose(id);
          }
        }
        for (final dose in desired) {
          if (!previous.containsKey(dose.id) ||
              previous[dose.id] != dose.scheduledTime) {
            await _port.scheduleForDose(
              dose: dose,
              medicationName: dose.medicationName ?? 'Medication',
            );
          }
        }
      }
    } catch (e) {
      // Whatever was already scheduled/cancelled up to the failure stands;
      // the previous snapshot is kept so the next reconcile still diffs
      // correctly rather than assuming a state we never fully reached.
      debugPrint(
        'Reminders: reconcile failed talking to the notification port: $e',
      );
      _lastError = e;
      return _scheduled?.length ?? 0;
    }

    _scheduled = desiredMap;
    _lastError = null;
    debugPrint(
      'Reminders: ${desiredMap.length} dose(s) scheduled (${pending.length} pending in horizon)',
    );
    return desiredMap.length;
  }
}
