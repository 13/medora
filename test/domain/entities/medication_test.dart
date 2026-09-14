import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  test('isExpiringSoon and expiredAt use the injected clock', () {
    final soon = Medication(
      id: 'a',
      name: 'a',
      quantity: 1,
      expiryDate: DateTime(2026, 3, 20),
    );
    final far = Medication(
      id: 'b',
      name: 'b',
      quantity: 1,
      expiryDate: DateTime(2027),
    );
    final past = Medication(
      id: 'c',
      name: 'c',
      quantity: 1,
      expiryDate: DateTime(2026, 3),
    );

    expect(soon.isExpiringSoon(now: now), isTrue);
    expect(far.isExpiringSoon(now: now), isFalse);
    expect(past.isExpiringSoon(now: now), isFalse);
    expect(past.expiredAt(now), isTrue);
    expect(soon.expiredAt(now), isFalse);
    expect(soon.daysUntilExpiry(now), 16);
  });

  test('defaults keep working without a clock', () {
    final far = Medication(
      id: 'b',
      name: 'b',
      quantity: 1,
      expiryDate: DateTime(2099),
    );
    expect(far.isExpiringSoon(), isFalse);
    expect(far.isExpired, isFalse);
  });

  test('no expiry date is never expiring or expired', () {
    const none = Medication(id: 'd', name: 'd', quantity: 1);
    expect(none.isExpiringSoon(now: now), isFalse);
    expect(none.expiredAt(now), isFalse);
    expect(none.daysUntilExpiry(now), isNull);
  });
}
