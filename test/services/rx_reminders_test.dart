import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/rx_reminders.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

void main() {
  final now = DateTime(2026, 9, 23, 10);
  RxWithDispensings entry(
    String id,
    DateTime? until, {
    List<RxDispensing> given = const [],
    String? medicationId,
  }) => RxWithDispensings(
    Rx(
      id: id,
      personId: 'p1',
      kind: RxKind.ssn,
      issuedOn: DateTime(2026, 9),
      validUntil: until,
      items: [
        RxItem(id: 'i1', medicationId: medicationId, description: 'Brufen'),
      ],
    ),
    given,
  );
  const persons = {'p1': Person(id: 'p1', name: 'Ben')};

  test('an open rx is reminded three days before its last day at 09:00', () {
    final alerts = rxExpiryAlertsFor(
      [entry('r1', DateTime(2026, 10))],
      persons,
      now,
    );
    expect(alerts.single.kind, StockAlertKind.rxExpiry);
    expect(alerts.single.when, DateTime(2026, 9, 28, 9));
    expect(alerts.single.days, 3);
    expect(alerts.single.medicationName, 'Ben – Brufen');
  });

  test('inside the three days: the next 09:00, then the last day', () {
    final a = rxExpiryAlertsFor(
      [entry('r1', DateTime(2026, 9, 25))],
      persons,
      now,
    );
    expect(a.single.when, DateTime(2026, 9, 24, 9));
    expect(a.single.days, 1);
  });

  test('past 09:00 on the last day: nothing left to remind', () {
    final a = rxExpiryAlertsFor(
      [entry('r1', DateTime(2026, 9, 23))],
      persons,
      DateTime(2026, 9, 23, 10),
    );
    expect(a, isEmpty);
  });

  test('collected, expired or without validity: no alert', () {
    final given = [
      RxDispensing(
        id: 'd',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 2),
      ),
    ];
    expect(
      rxExpiryAlertsFor(
        [
          entry('r1', DateTime(2026, 10), given: given),
          entry('r2', DateTime(2026, 9)),
          entry('r3', null),
        ],
        persons,
        now,
      ),
      isEmpty,
    );
  });

  test('a low, planned medication without an open rx needs one', () {
    final low = [
      const Medication(
        id: 'm1',
        name: 'Brufen',
        quantity: 2,
        minimumStockLevel: 5,
      ),
      const Medication(
        id: 'm2',
        name: 'Tachipirina',
        quantity: 1,
        minimumStockLevel: 5,
      ),
      const Medication(
        id: 'm3',
        name: 'Aspirin',
        quantity: 0,
        minimumStockLevel: 5,
      ),
    ];
    final needs = medicationsNeedingRx(
      lowStock: low,
      planned: {'m1', 'm2'},
      rx: [entry('r1', DateTime(2026, 10), medicationId: 'm2')],
      now: now,
    );
    // m1: planned, low, no rx. m2: covered by an open rx. m3: not planned.
    expect(needs, {'m1'});
  });
}
