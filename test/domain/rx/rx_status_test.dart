import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/rx/rx_rules.dart';

void main() {
  final now = DateTime(2026, 9, 23, 10);
  const item = RxItem(
    id: 'i1',
    description: 'Tachipirina 20 compresse',
    packs: 2,
  );
  const other = RxItem(id: 'i2', description: 'Brufen');
  final rx = Rx(
    id: 'r1',
    kind: RxKind.ssn,
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [item, other],
  );
  RxDispensing give(String itemId, int packs) => RxDispensing(
    id: '$itemId-$packs',
    rxId: 'r1',
    itemId: itemId,
    packs: packs,
    dispensedOn: DateTime(2026, 9, 22),
  );

  test('no dispensing: open', () {
    expect(RxRules.statusOf(rx, const [], now), RxStatus.open);
  });

  test('some packs dispensed: partial', () {
    expect(RxRules.statusOf(rx, [give('i1', 1)], now), RxStatus.partial);
  });

  test('every item fully dispensed: redeemed', () {
    expect(
      RxRules.statusOf(rx, [give('i1', 1), give('i1', 1), give('i2', 1)], now),
      RxStatus.redeemed,
    );
  });

  test('closed by hand: redeemed, even without dispensings', () {
    expect(
      RxRules.statusOf(
        rx.copyWith(closedOn: DateTime(2026, 9, 21)),
        const [],
        now,
      ),
      RxStatus.redeemed,
    );
  });

  test('past its last valid day: expired; the last day itself is valid', () {
    expect(
      RxRules.statusOf(rx, const [], DateTime(2026, 10, 20, 23, 59)),
      RxStatus.open,
    );
    expect(
      RxRules.statusOf(rx, const [], DateTime(2026, 10, 21)),
      RxStatus.expired,
    );
  });

  test('cancelled wins over everything', () {
    expect(
      RxRules.statusOf(rx.copyWith(cancelled: true), [give('i1', 2)], now),
      RxStatus.cancelled,
    );
  });

  test('redeemed wins over expired', () {
    expect(
      RxRules.statusOf(rx, [give('i1', 2), give('i2', 1)], DateTime(2026, 12)),
      RxStatus.redeemed,
    );
  });

  RxDispensing giveOn(String itemId, DateTime day) => RxDispensing(
    id: '$itemId-${day.day}',
    rxId: 'r1',
    itemId: itemId,
    packs: 1,
    dispensedOn: day,
  );

  test('a repeatable prescription is redeemed after its max pharmacy visits: '
      'two items collected on one day are one visit', () {
    final rep = rx.copyWith(kind: RxKind.whiteRepeatable, maxDispensings: 2);
    final day1 = DateTime(2026, 9, 21);
    final day2 = DateTime(2026, 9, 22);
    expect(RxRules.statusOf(rep, [giveOn('i1', day1)], now), RxStatus.partial);
    expect(
      RxRules.statusOf(rep, [giveOn('i1', day1), giveOn('i2', day1)], now),
      RxStatus.partial,
    );
    expect(
      RxRules.statusOf(rep, [giveOn('i1', day1), giveOn('i1', day2)], now),
      RxStatus.redeemed,
    );
  });

  test('an rx without items and without closedOn stays open', () {
    final referral = Rx(
      id: 'r2',
      kind: RxKind.referral,
      issuedOn: DateTime(2026, 9, 20),
    );
    expect(RxRules.statusOf(referral, const [], now), RxStatus.open);
  });

  test('dispensedPacks sums per item', () {
    expect(
      RxRules.dispensedPacks([give('i1', 1), give('i1', 1), give('i2', 1)]),
      {'i1': 2, 'i2': 1},
    );
  });

  test('daysLeft counts calendar days to the last valid day', () {
    expect(RxRules.daysLeft(rx, now), 27);
    expect(RxRules.daysLeft(rx, DateTime(2026, 10, 20, 22)), 0);
    expect(
      RxRules.daysLeft(
        Rx(id: 'x', kind: RxKind.referral, issuedOn: DateTime(2026, 9)),
        now,
      ),
      isNull,
    );
  });

  test('packSizeOf reads the count in a pack description', () {
    expect(RxRules.packSizeOf('Tachipirina 500 mg 20 compresse'), 20);
    expect(RxRules.packSizeOf('Brufen 400mg 30 cpr rivestite'), 30);
    expect(RxRules.packSizeOf('Aspirin 20 Tabletten'), 20);
    expect(RxRules.packSizeOf('Sciroppo 150 ml'), isNull);
    expect(RxRules.packSizeOf('Brufen'), isNull);
  });
}
