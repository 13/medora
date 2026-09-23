import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/rx_rules.dart';

void main() {
  final issued = DateTime(2026, 9, 23);

  test('SSN and white prescriptions are valid 30 days after issue', () {
    expect(
      RxValidity.defaultValidUntil(RxKind.ssn, issued),
      DateTime(2026, 10, 23),
    );
    expect(
      RxValidity.defaultValidUntil(RxKind.white, issued),
      DateTime(2026, 10, 23),
    );
  });

  test('a repeatable white prescription lasts six months, ten dispensings', () {
    expect(
      RxValidity.defaultValidUntil(RxKind.whiteRepeatable, issued),
      DateTime(2027, 3, 23),
    );
    expect(RxValidity.defaultMaxDispensings(RxKind.whiteRepeatable), 10);
    expect(RxValidity.defaultMaxDispensings(RxKind.ssn), isNull);
  });

  test('six months from 31 August clamps to the month end', () {
    expect(
      RxValidity.defaultValidUntil(
        RxKind.whiteRepeatable,
        DateTime(2026, 8, 31),
      ),
      DateTime(2027, 2, 28),
    );
  });

  test('a referral has no default validity', () {
    expect(RxValidity.defaultValidUntil(RxKind.referral, issued), isNull);
  });

  test('visit-by dates follow the priority class', () {
    expect(RxValidity.visitBy(RxPriority.u, issued), DateTime(2026, 9, 26));
    expect(RxValidity.visitBy(RxPriority.b, issued), DateTime(2026, 10, 3));
    expect(RxValidity.visitBy(RxPriority.d, issued), DateTime(2026, 10, 23));
    expect(RxValidity.visitBy(RxPriority.p, issued), DateTime(2027, 1, 21));
  });

  test('wire names round-trip, unknown kinds read as SSN', () {
    for (final k in RxKind.values) {
      expect(RxKind.fromWire(k.wire), k);
    }
    expect(RxKind.fromWire('nonsense'), RxKind.ssn);
    expect(RxPriority.fromWire('B'), RxPriority.b);
    expect(RxPriority.fromWire(null), isNull);
  });
}
