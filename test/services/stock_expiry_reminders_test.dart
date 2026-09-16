import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
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
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final now = DateTime(2026, 9, 16, 10); // after 09:00

  test('an expiry inside the window fires at the next 09:00', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 10, 1)),
    ], now);
    expect(alerts, hasLength(1));
    expect(alerts.single.kind, StockAlertKind.expiry);
    expect(alerts.single.days, 15);
    expect(alerts.single.when, DateTime(2026, 9, 17, 9));
  });

  test('an expiry beyond the window fires when the window opens', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 12, 1)),
    ], now);
    expect(alerts.single.when, DateTime(2026, 11, 1, 9));
    expect(alerts.single.days, 76);
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
    expect(alerts.single.days, 0);
  });

  test('quantity at or below the minimum is low stock', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 2, minimumStockLevel: 2),
      _med(id: 'b', quantity: 3, minimumStockLevel: 2),
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
  });

  test('alerts come earliest first and honour the limit', () {
    final alerts = stockAlertsFor(
      [
        _med(id: 'a', expiryDate: DateTime(2026, 12, 1)),
        _med(id: 'b', quantity: 0),
      ],
      now,
      limit: 1,
    );
    expect(alerts, hasLength(1));
    expect(alerts.single.medicationId, 'b'); // 17 Sep beats 1 Nov
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
