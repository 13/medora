/// Medora - Stock, expiry and prescription-expiry reminder scheduler.
///
/// The second scheduler: it owns stock, expiry and prescription-expiry
/// notifications, while [ReminderScheduler] owns the dose reminders. The two
/// never disturb each other because [stockAlertId] hands out ids in slots
/// (offsets 8, 9 and 10) that dose reminders never take — which is also why
/// this one never calls `cancelAll()`, and why the dose scheduler's own full
/// cancel spares those three offsets. It cancels its own ids one by one,
/// from the snapshot of the previous run, which is persisted so a restart
/// still knows them.
///
/// The snapshot records what each alert *says* ([StockAlert.fingerprint]),
/// not merely when it fires: the text is baked in at booking time, so a
/// rename or a changed quantity has to re-book an alert that still fires at
/// the same moment.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/rerun_guard.dart';
import 'package:medora/services/rx_reminders.dart';
import 'package:medora/services/stock_alert_store.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

/// What the prescription reminders need, read once per reconcile.
class RxReminderInputs {
  const RxReminderInputs({
    required this.rx,
    required this.persons,
    required this.plannedMedicationIds,
  });

  final List<RxWithDispensings> rx;
  final Map<String, Person> persons;

  /// Medications of active dosing plans.
  final Set<String> plannedMedicationIds;
}

class StockReminderScheduler {
  StockReminderScheduler({
    required this._port,
    required this._medications,
    required bool Function() stockRemindersEnabled,
    Now? now,
    StockAlertStore? store,
    this._rxInputs,
  }) : _enabled = stockRemindersEnabled,
       _now = now ?? systemNow,
       _store = store ?? StockAlertStore.inMemory();

  final ReminderPort _port;
  final MedicationRepository _medications;
  final bool Function() _enabled;
  final Now _now;
  final StockAlertStore _store;

  /// Reads the prescriptions, persons and planned medications a reconcile
  /// needs to plan prescription-expiry alerts. Null (no seam given, in
  /// tests that do not exercise prescriptions) plans none.
  final Future<RxReminderInputs?> Function()? _rxInputs;

  /// The previous run's alerts: notification id → what it says
  /// ([StockAlert.fingerprint]).
  final Map<int, String> _scheduled = {};

  /// Whether [_scheduled] has been seeded from the store yet. The first run
  /// of a session inherits the last session's ids, so alerts for medications
  /// that were restocked or deleted while the app was closed are cancelled
  /// instead of firing.
  bool _restored = false;

  final _reruns = RerunGuard();

  /// Forget what the booked alerts say, so the next [reconcile] books them
  /// all again.
  ///
  /// The ids are kept — loaded from the store when this session has not read
  /// it yet — because they are the only handle on an alert the cabinet no
  /// longer wants. Only their content is forgotten, which makes every
  /// surviving alert be re-booked (in place, over the same id) and every
  /// abandoned one be cancelled.
  void reset() {
    if (!_restored) {
      _restored = true;
      _scheduled.addAll(_store.load());
    }
    for (final id in _scheduled.keys.toList()) {
      _scheduled[id] = StockAlertStore.unknownFingerprint;
    }
  }

  /// Reconciles the scheduled alerts with the ones the cabinet now wants, and
  /// returns how many are scheduled.
  ///
  /// A reconcile requested while one is running is not dropped: the running
  /// one reruns before returning. Without this, the startup run and the
  /// Settings switch can interleave and leave the snapshot describing a state
  /// that was never reached.
  Future<int> reconcile() => _reruns.run(_reconcileOnce);

  Future<int> _reconcileOnce() async {
    await _restore();

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

    // Null (no inputs, or they failed to load) plans no prescription alerts
    // but keeps every stock alert: a prescription read must never cost the
    // cabinet its reminders. Any rx alert already booked is preserved
    // separately below (see `keptRxAlerts`), by id, since there is nothing
    // here to rebuild it from.
    RxReminderInputs? rx;
    try {
      rx = await _rxInputs?.call();
    } catch (e) {
      debugPrint('Stock reminders: could not load prescriptions: $e');
    }
    final now = _now();
    // Chose the simpler of the two options for a failed rx read: a low-stock
    // alert's `askForRx` is recomputed from `needsRx` regardless (so it can
    // flip off and re-book that alert without its "ask your doctor" line
    // until the next successful read), rather than also freezing every
    // low-stock fingerprint to dodge that. The one guarantee this method
    // keeps is that a prescription read never costs the cabinet a *booked
    // alert* — stock or rx.
    final needsRx = rx == null
        ? const <String>{}
        : medicationsNeedingRx(
            lowStock: medications,
            planned: rx.plannedMedicationIds,
            rx: rx.rx,
            now: now,
          );
    final desired = {
      for (final alert in sortAndCapAlerts([
        ...stockAlertsFor(medications, now, needsRx: needsRx),
        if (rx != null) ...rxExpiryAlertsFor(rx.rx, rx.persons, now),
      ]))
        alert.id: alert,
    };
    final toSchedule = desired.values
        .where((alert) => _scheduled[alert.id] != alert.fingerprint)
        .toList();

    // Asked here rather than at startup because this is the first moment the
    // app actually needs the permission — and only when there is something to
    // show, so an empty cabinet never raises a dialog. The setting is on by
    // default, so without this a user who never opens Settings would never be
    // asked and the alerts would be scheduled into the void.
    if (toSchedule.isNotEmpty && !await _permitted()) return _scheduled.length;

    try {
      for (final id in _scheduled.keys.toList()) {
        // A failed prescription read must not cost the cabinet its
        // already-booked rx alerts: with no fresh `RxReminderInputs` there is
        // no `StockAlert` to diff against, so the id is left exactly as it
        // was rather than read as "no longer wanted" and cancelled. (Its
        // `askForRx` low-stock sibling, if any, does not get the same
        // treatment here — see the comment on `keptRxAlerts` below.)
        if (rx == null && isRxAlertId(id)) continue;
        // Gone, moved, or saying something else now: the old notification
        // must go before the replacement is booked.
        if (desired[id]?.fingerprint != _scheduled[id]) {
          await _port.cancelStockAlert(id);
        }
      }
      for (final alert in toSchedule) {
        await _port.scheduleStockAlert(alert);
      }
    } catch (e) {
      // Whatever landed before the failure stands; the snapshot is kept so
      // the next run still diffs against a state we actually reached.
      debugPrint('Stock reminders: the notification port failed: $e');
      return _scheduled.length;
    }

    // The ids skipped above are not in `desired` (rx == null means
    // `rxExpiryAlertsFor` never ran), so a plain rebuild from `desired.values`
    // would silently drop them from the snapshot even though nothing was
    // cancelled or re-booked. Carry them over untouched.
    final keptRxAlerts = rx == null
        ? {
            for (final id in _scheduled.keys)
              if (isRxAlertId(id)) id: _scheduled[id]!,
          }
        : const <int, String>{};
    _scheduled
      ..clear()
      ..addEntries(desired.values.map((a) => MapEntry(a.id, a.fingerprint)))
      ..addAll(keptRxAlerts);
    await _store.save(_scheduled);
    debugPrint('Stock reminders: ${_scheduled.length} alert(s) scheduled');
    return _scheduled.length;
  }

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    _scheduled.addAll(_store.load());
  }

  /// Whether the OS will actually show what we schedule.
  ///
  /// A denial is not an error the user needs to see here — the Settings
  /// switch is where it is explained — so the feature simply goes quiet and
  /// picks up again on the next reconcile if permission is granted later.
  Future<bool> _permitted() async {
    try {
      final granted = await _port.ensurePermissions();
      if (!granted) {
        debugPrint('Stock reminders: notifications are not permitted');
      }
      return granted;
    } catch (e) {
      debugPrint('Stock reminders: could not check the permission: $e');
      return false;
    }
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
    await _store.save(_scheduled);
  }
}
