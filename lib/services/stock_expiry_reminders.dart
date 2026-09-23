/// Medora - which stock and expiry notifications should exist
///
/// Pure planning, mirroring `ReminderScheduler`'s split: this decides *what*
/// should be scheduled and when, `StockReminderScheduler` diffs it against
/// what is scheduled already. Both take an injected clock, so the tests
/// state exact times.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/services/notification_budget.dart';

enum StockAlertKind { expiry, lowStock, rxExpiry }

/// The hour of day stock and expiry notifications fire.
const int stockAlertHour = 9;

/// How far ahead alerts are booked, mirroring `ReminderScheduler.horizon`.
///
/// A medication expiring in 2031 needs no OS alarm today: the reconcile runs
/// on every launch and resume, so anything past the horizon is booked by a
/// later run long before its window opens. Bounding it is what keeps the
/// nearest alerts inside [kStockNotificationBudget].
const int stockAlertHorizonDays = 90;

@immutable
class StockAlert {
  const StockAlert({
    required this.id,
    required this.medicationId,
    required this.medicationName,
    required this.kind,
    required this.when,
    required this.days,
    required this.quantity,
    this.askForRx = false,
  });

  final int id;

  /// For [StockAlertKind.rxExpiry], the prescription's id.
  final String medicationId;

  /// For [StockAlertKind.rxExpiry], the prescription's label.
  final String medicationName;
  final StockAlertKind kind;

  /// A low-stock alert for a medication taken on a schedule with no open
  /// prescription left: the notification also says to ask for one.
  final bool askForRx;

  /// Local time the notification fires. Always [stockAlertHour]:00.
  final DateTime when;

  /// Days from [when] to the expiry date for [StockAlertKind.expiry], else 0.
  ///
  /// Counted from *delivery*, not from planning: the body text is baked in
  /// when the notification is scheduled, which can be months before it is
  /// shown, so a count taken at planning time would arrive stale.
  final int days;

  /// Stock left for [StockAlertKind.lowStock], else 0.
  final int quantity;

  /// Everything the delivered notification will say, in one value.
  ///
  /// The scheduler diffs on this rather than on [when] alone: the title and
  /// body are baked in when the alert is booked, so a rename or a changed
  /// quantity has to re-book it even though it still fires at the same
  /// moment. Without that, taking the last two tablets at 11:00 leaves
  /// tomorrow's notification saying "2 left" for an empty box.
  String get fingerprint =>
      '${when.millisecondsSinceEpoch}|${kind.index}|$days|$quantity|'
      '$medicationName|${askForRx ? 1 : 0}';
}

/// Notification id for one medication (or prescription, for
/// [StockAlertKind.rxExpiry]) and kind.
///
/// Shares `ReminderService.notificationBaseId`'s hash space but uses offsets
/// 8, 9 and 10, which dose reminders (offsets 0-3) never take.
int stockAlertId(String medicationId, StockAlertKind kind) {
  var hash = 0x811C9DC5;
  for (final unit in medicationId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  // Dose reminders take offsets 0-3 of the same 16-slot block.
  return (hash & 0x7FFFFFF0) |
      switch (kind) {
        StockAlertKind.expiry => 0x8,
        StockAlertKind.lowStock => 0x9,
        StockAlertKind.rxExpiry => 0xA,
      };
}

/// The next [stockAlertHour]:00 at or after both [from] and [now].
///
/// [now] itself never qualifies: an alert planned at 10:00 today fires at
/// 09:00 tomorrow, not at an hour that has already passed.
///
/// All the arithmetic goes through the normalising [DateTime] constructor
/// rather than a [Duration]: a duration is exact elapsed time, so adding one
/// "day" across a daylight-saving transition moves the wall-clock hour, and
/// these alerts exist to fire at [stockAlertHour] sharp.
///
/// Public because the prescription-expiry planner (`rx_reminders.dart`)
/// books alerts on the same hour and reuses this exactly rather than
/// duplicating it.
DateTime nextAlertTime(DateTime from, DateTime now) {
  final day = DateTime(from.year, from.month, from.day, stockAlertHour);
  final today = DateTime(now.year, now.month, now.day, stockAlertHour);
  final earliest = now.isBefore(today)
      ? today
      : DateTime(now.year, now.month, now.day + 1, stockAlertHour);
  return day.isAfter(earliest) ? day : earliest;
}

/// The alerts due for [medications] at [now].
///
/// An expiry alert for every unarchived medication that has not expired yet,
/// and a low-stock alert for every unarchived medication whose quantity is at
/// or below its minimum stock level.
///
/// Each alert fires at [stockAlertHour]:00 local — on the day the expiry
/// window opens ([expiryLeadDays] before the expiry date), or the next
/// [stockAlertHour]:00 after [now], whichever is later. A medication expiring
/// inside [horizonDays] therefore gets its notification booked now and
/// delivered when the window opens, even if the app is never opened in
/// between; anything further out is left to a later run.
///
/// Earliest first, at most [limit] — so the nearest alerts win the limited
/// pool of pending OS notifications, and a distant expiry can never crowd out
/// something due tomorrow.
List<StockAlert> stockAlertsFor(
  List<Medication> medications,
  DateTime now, {
  int expiryLeadDays = AppConstants.expiryWarningDays,
  int horizonDays = stockAlertHorizonDays,
  int limit = kStockNotificationBudget,
  Set<String> needsRx = const {},
}) {
  final horizon = DateTime(
    now.year,
    now.month,
    now.day + horizonDays,
    stockAlertHour,
  );
  final alerts = <StockAlert>[];
  for (final m in medications) {
    if (m.isArchived) continue;
    final expiry = m.expiryDate;
    if (expiry != null && !m.expiredAt(now)) {
      final when = nextAlertTime(
        DateTime(expiry.year, expiry.month, expiry.day - expiryLeadDays),
        now,
      );
      if (!when.isAfter(horizon)) {
        // Counted from delivery, so the text is right when it is read. A
        // medication that expires before the next slot (it expires today,
        // and 09:00 has passed) reads "today" rather than a negative count.
        final remaining = calendarDaysBetween(when, expiry);
        alerts.add(
          StockAlert(
            id: stockAlertId(m.id, StockAlertKind.expiry),
            medicationId: m.id,
            medicationName: m.name,
            kind: StockAlertKind.expiry,
            when: when,
            days: remaining < 0 ? 0 : remaining,
            quantity: 0,
          ),
        );
      }
    }
    if (m.isLowStock) {
      alerts.add(
        StockAlert(
          id: stockAlertId(m.id, StockAlertKind.lowStock),
          medicationId: m.id,
          medicationName: m.name,
          kind: StockAlertKind.lowStock,
          when: nextAlertTime(now, now),
          days: 0,
          quantity: m.quantity,
          askForRx: needsRx.contains(m.id),
        ),
      );
    }
  }
  return sortAndCapAlerts(alerts, limit: limit);
}

/// Earliest first, at most [limit].
///
/// The id is a tie-break, not decoration: every low-stock alert (and every
/// prescription-expiry alert booked on the same reconcile) can carry the
/// same `when`, which is a total tie, and `List.sort` is not stable — so
/// without it the order the source list happened to return would decide
/// which alert silently loses to the limit below. Shared by [stockAlertsFor]
/// and the scheduler's merge of stock and prescription alerts, so both kinds
/// compete for the same pending-notification budget on equal terms.
List<StockAlert> sortAndCapAlerts(
  List<StockAlert> alerts, {
  int limit = kStockNotificationBudget,
}) {
  final sorted = [...alerts]
    ..sort((a, b) {
      final byTime = a.when.compareTo(b.when);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return sorted.length > limit ? sorted.sublist(0, limit) : sorted;
}
