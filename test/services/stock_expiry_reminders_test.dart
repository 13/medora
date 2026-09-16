import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/services/notification_budget.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

Medication _med({
  required String id,
  String name = 'Aspirin',
  int quantity = 10,
  int minimumStockLevel = 2,
  DateTime? expiryDate,
  bool isArchived = false,
}) => Medication(
  id: id,
  name: name,
  quantity: quantity,
  minimumStockLevel: minimumStockLevel,
  expiryDate: expiryDate,
  isArchived: isArchived,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// The local day in [year] on which the clocks go forward, or null in a zone
/// without daylight saving (a UTC CI machine).
///
/// The DST tests below assert the same thing either way — that the alert
/// keeps its wall-clock hour and calendar day. In a zone with DST those
/// assertions fail under `Duration`-based arithmetic, which is exact elapsed
/// time rather than calendar time; in UTC they hold trivially.
DateTime? _springForwardDay(int year) {
  for (
    var day = DateTime(year);
    day.year == year;
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    final next = DateTime(day.year, day.month, day.day + 1);
    if (next.timeZoneOffset > day.timeZoneOffset) return day;
  }
  return null;
}

void main() {
  final now = DateTime(2026, 9, 16, 10); // after 09:00

  test('an expiry inside the window fires at the next 09:00', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 10)),
    ], now);
    expect(alerts, hasLength(1));
    expect(alerts.single.kind, StockAlertKind.expiry);
    expect(alerts.single.when, DateTime(2026, 9, 17, 9));
    expect(
      alerts.single.days,
      14,
      reason: 'the count is what the user reads on delivery, not at planning',
    );
  });

  test('an expiry beyond the window fires when the window opens', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 12)),
    ], now);
    expect(alerts.single.when, DateTime(2026, 11, 1, 9));
    expect(
      alerts.single.days,
      30,
      reason: 'a window-opening alert always says the lead time',
    );
  });

  test('an expired medication gets no alert', () {
    expect(
      stockAlertsFor([_med(id: 'a', expiryDate: DateTime(2026, 9, 15))], now),
      isEmpty,
    );
  });

  test('expiring today still alerts (good for the whole day)', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 9, 16)),
    ], now);
    expect(
      alerts.single.days,
      0,
      reason: 'delivered tomorrow morning, it must never read a negative count',
    );
  });

  test('an expiry past the horizon is left for a later run', () {
    expect(
      stockAlertsFor([_med(id: 'a', expiryDate: DateTime(2031))], now),
      isEmpty,
      reason: 'booking OS alarms years ahead only crowds the pending queue',
    );
    expect(
      stockAlertsFor(
        [_med(id: 'a', expiryDate: DateTime(2026, 12))],
        now,
        horizonDays: 30,
      ),
      isEmpty,
      reason: '1 Nov is more than 30 days after 16 Sep',
    );
  });

  test('quantity at or below the minimum is low stock', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 2),
      _med(id: 'b', quantity: 3, minimumStockLevel: 1),
    ], now);
    expect(alerts.map((a) => a.medicationId), ['a']);
    expect(alerts.single.kind, StockAlertKind.lowStock);
    expect(alerts.single.quantity, 2);
    expect(alerts.single.when, DateTime(2026, 9, 17, 9));
  });

  test('before 09:00 the alert is today', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 0),
    ], DateTime(2026, 9, 16, 7));
    expect(alerts.single.when, DateTime(2026, 9, 16, 9));
  });

  test('archived medications are ignored', () {
    expect(
      stockAlertsFor([_med(id: 'a', quantity: 0, isArchived: true)], now),
      isEmpty,
    );
  });

  test('one medication can raise both alerts, with different ids', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 0, expiryDate: DateTime(2026, 9, 20)),
    ], now);
    expect(alerts.map((a) => a.kind), containsAll(StockAlertKind.values));
    expect(alerts.map((a) => a.id).toSet(), hasLength(2));
    expect(
      alerts.firstWhere((a) => a.kind == StockAlertKind.expiry).quantity,
      0,
      reason: 'quantity is meaningless for an expiry alert',
    );
  });

  test('alerts come earliest first and honour the limit', () {
    final alerts = stockAlertsFor(
      [
        _med(id: 'a', expiryDate: DateTime(2026, 12)),
        _med(id: 'b', quantity: 0),
      ],
      now,
      limit: 1,
    );
    expect(alerts, hasLength(1));
    expect(alerts.single.medicationId, 'b'); // 17 Sep beats 1 Nov
  });

  test('the default limit is the app-wide stock share', () {
    final many = [
      for (var i = 0; i < kStockNotificationBudget + 5; i++)
        _med(id: 'm$i', quantity: 0),
    ];
    expect(stockAlertsFor(many, now), hasLength(kStockNotificationBudget));
  });

  test('a tie on time is broken by id, so the cabinet order cannot drop an '
      'arbitrary alert', () {
    // Every low-stock alert carries the same `when`, which is a total tie:
    // with more of them than the budget, an unstable sort would let the
    // order the rows came back in decide whose alert is silently dropped.
    final many = [
      for (var i = 0; i < kStockNotificationBudget + 3; i++)
        _med(id: 'm$i', name: 'M$i', quantity: 0),
    ];

    final asListed = stockAlertsFor(many, now).map((a) => a.id).toList();
    final reversed = stockAlertsFor(
      many.reversed.toList(),
      now,
    ).map((a) => a.id).toList();

    expect(asListed, hasLength(kStockNotificationBudget));
    expect(
      reversed,
      asListed,
      reason: 'renaming one medication must not cost another its alert',
    );
  });

  test('the next alert keeps 09:00 across a daylight-saving change', () {
    final spring = _springForwardDay(2026) ?? DateTime(2026, 3, 29);
    // The day *before* the transition: "tomorrow at 09:00" is where 24 exact
    // hours land on the wrong hour.
    final eve = DateTime(spring.year, spring.month, spring.day - 1, 10);
    final alerts = stockAlertsFor([_med(id: 'a', quantity: 0)], eve);
    expect(
      alerts.single.when,
      DateTime(spring.year, spring.month, spring.day, 9),
    );
    expect(alerts.single.when.hour, stockAlertHour);
  });

  test('the expiry window opens on the right day across a DST change', () {
    final spring = _springForwardDay(2026) ?? DateTime(2026, 3, 29);
    final expiry = DateTime(spring.year, spring.month, spring.day + 30);
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: expiry),
    ], DateTime(2026, 1, 15, 10));
    expect(
      alerts.single.when,
      DateTime(spring.year, spring.month, spring.day, 9),
      reason: 'subtracting 30 exact days lands an hour into the previous day',
    );
    expect(alerts.single.days, 30);
  });

  test('ids are stable, per kind, and clear of dose reminder offsets', () {
    final first = stockAlertId('a', StockAlertKind.expiry);
    expect(first, stockAlertId('a', StockAlertKind.expiry));
    expect(first, isNot(stockAlertId('a', StockAlertKind.lowStock)));
    expect(first & 0xF, 8);
    expect(stockAlertId('a', StockAlertKind.lowStock) & 0xF, 9);
    expect(first, lessThan(0x7FFFFFFF));
  });
}
