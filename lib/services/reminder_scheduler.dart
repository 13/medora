/// Medora - Reminder scheduler.
///
/// Single owner of "which notifications exist". [reconcile] schedules
/// pending doses for the next [horizon], earliest first, capped at
/// [maxNotifications]. The first run (or the first after [reset]) cancels
/// every pending *dose* reminder and schedules the desired set — never
/// `cancelAll()`, which would take the stock and expiry alerts of the other
/// scheduler with it (see [ReminderPort.cancelAllDoses]); later runs diff
/// against the
/// previous run's snapshot and only cancel/schedule the delta. The snapshot
/// tracks id and scheduled time; a dose whose time changes (e.g. after a
/// cloud pull) is re-scheduled. When reminders are disabled it cancels
/// everything and schedules nothing.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/notification_budget.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/rerun_guard.dart';

class ReminderScheduler {
  ReminderScheduler({
    required this._port,
    required this._doses,
    required this._remindersEnabled,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const horizon = Duration(days: 7);

  /// This scheduler's share of the app-wide pending-notification budget;
  /// the stock and expiry alerts spend the rest (see notification_budget).
  static const maxNotifications = kDoseNotificationBudget;
  static const notificationsPerDose = 2;

  final ReminderPort _port;
  final DoseLogRepository _doses;
  final bool Function() _remindersEnabled;
  final DateTime Function() _now;

  final _reruns = RerunGuard();

  /// The message from the most recent reconcile attempt, or null when the
  /// last attempt succeeded. A failed attempt keeps the previous snapshot
  /// and notification set untouched — this is purely for callers that want
  /// to surface "reminders may be out of date" somewhere, so it is already
  /// a string rather than an arbitrary thrown object.
  String? get lastError => _lastError;
  String? _lastError;

  /// Returns the number of doses that received notifications.
  ///
  /// If a reconcile is requested while one is already running, it is not
  /// dropped: the running reconcile reruns once more before returning.
  Future<int> reconcile() => _reruns.run(_reconcileOnce);

  /// Snapshot of the previous run: dose id → scheduled time. Null means
  /// "unknown, do a full cancel".
  Map<String, DateTime>? _scheduled;

  void reset() => _scheduled = null;

  Future<int> _reconcileOnce() async {
    if (!_remindersEnabled()) {
      await _port.cancelAllDoses();
      _scheduled = {};
      _lastError = null;
      return 0;
    }
    final now = _now();
    final result = await _doses.getPendingDoseLogsBetween(
      now,
      now.add(horizon),
    );
    String? loadError;
    final pending = result.when(
      success: (d) => d,
      failure: (msg) {
        debugPrint('Reminders: could not load pending doses: $msg');
        loadError = msg;
        return null;
      },
    );
    if (pending == null) {
      // Report what actually went wrong, not a synthesised placeholder — the
      // repository's message is the only clue a caller surfacing "reminders
      // may be out of date" has.
      _lastError = loadError ?? 'could not load pending doses';
      return _scheduled?.length ?? 0;
    }

    const limit = maxNotifications ~/ notificationsPerDose;
    final desired = pending.take(limit).toList();
    final desiredMap = {for (final d in desired) d.id: d.scheduledTime};
    final previous = _scheduled;

    try {
      if (previous == null) {
        await _port.cancelAllDoses();
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
      _lastError = '$e';
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
