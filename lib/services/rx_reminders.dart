/// Medora - Which prescription notifications should exist.
///
/// Planned like the stock and expiry alerts (same hour, same id block,
/// booked by the same scheduler), so the two never disturb each other.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

/// Days before its last valid day that an open prescription is reminded.
const int rxExpiryLeadDays = 3;

/// One alert per open prescription with a known last day: the first of
/// "three days before" and "the last day" still ahead of [now].
///
/// One id per prescription, so only one of the two is booked at a time.
/// The scheduler runs on every launch and resume, so once the first has
/// fired the next run books the second.
List<StockAlert> rxExpiryAlertsFor(
  List<RxWithDispensings> rx,
  Map<String, Person> persons,
  DateTime now, {
  int leadDays = rxExpiryLeadDays,
}) {
  final alerts = <StockAlert>[];
  for (final entry in rx) {
    final status = entry.statusAt(now);
    if (status != RxStatus.open && status != RxStatus.partial) continue;
    final until = entry.rx.validUntil;
    if (until == null) continue;
    final last = DateTime(until.year, until.month, until.day, stockAlertHour);
    final lead = DateTime(
      until.year,
      until.month,
      until.day - leadDays,
      stockAlertHour,
    );
    final when = nextAlertTime(lead, now);
    if (when.isAfter(last)) continue;
    alerts.add(
      StockAlert(
        id: stockAlertId(entry.rx.id, StockAlertKind.rxExpiry),
        medicationId: entry.rx.id,
        medicationName: _label(entry, persons),
        kind: StockAlertKind.rxExpiry,
        when: when,
        days: calendarDaysBetween(when, until),
        quantity: 0,
      ),
    );
  }
  return alerts;
}

/// "Ben – Brufen, Tachipirina": who it is for and what it is for.
String _label(RxWithDispensings entry, Map<String, Person> persons) {
  final person = persons[entry.rx.personId]?.name;
  final items = entry.rx.items.map((i) => i.description).join(', ');
  return [?person, if (items.isNotEmpty) items].join(' – ');
}

/// Low-stock medications taken on a schedule ([planned]) that no open
/// prescription covers: the ones to ask the doctor about.
Set<String> medicationsNeedingRx({
  required List<Medication> lowStock,
  required Set<String> planned,
  required List<RxWithDispensings> rx,
  required DateTime now,
}) {
  final covered = <String>{
    for (final entry in rx)
      if (entry.statusAt(now) case RxStatus.open || RxStatus.partial)
        for (final item in entry.rx.items) ?item.medicationId,
  };
  return {
    for (final m in lowStock)
      if (m.isLowStock && planned.contains(m.id) && !covered.contains(m.id))
        m.id,
  };
}
