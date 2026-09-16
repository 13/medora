import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/treatment.dart';

Treatment _t({
  DateTime? sickLeaveFrom,
  DateTime? sickLeaveTo,
  String? sickLeaveRef,
  String? doctor,
}) => Treatment(
  id: 't1',
  name: 'Stirnhöhlenentzündung',
  startDate: DateTime(2026, 3, 2),
  sickLeaveFrom: sickLeaveFrom,
  sickLeaveTo: sickLeaveTo,
  sickLeaveRef: sickLeaveRef,
  doctor: doctor,
);

void main() {
  group('hasSickLeave / isSickLeaveOpen', () {
    test('no sick leave recorded', () {
      final t = _t();
      expect(t.hasSickLeave, isFalse);
      expect(t.isSickLeaveOpen, isFalse);
    });

    test('an open leave has a start and no end', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.hasSickLeave, isTrue);
      expect(t.isSickLeaveOpen, isTrue);
    });

    test('a closed leave has both', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
      );
      expect(t.hasSickLeave, isTrue);
      expect(t.isSickLeaveOpen, isFalse);
    });
  });

  group('sickLeaveDaysAt', () {
    test('is null when no leave is recorded', () {
      expect(_t().sickLeaveDaysAt(DateTime(2026, 3, 10)), isNull);
    });

    test('counts both end days: Mon to Fri is five days, not four', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 2), // Monday
        sickLeaveTo: DateTime(2026, 3, 6), // Friday
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), 5);
    });

    test('a single day counts as one', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 3),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), 1);
    });

    test('an open leave counts up to now', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5)), 3);
    });

    test('the time of day in now is ignored', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5, 23, 30)), 3);
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5, 0, 1)), 3);
    });

    test('a DST transition inside the range does not shave a day', () {
      // Europe/Rome moves to summer time on 2026-03-29.
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 28),
        sickLeaveTo: DateTime(2026, 3, 30),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 4, 2)), 3);
    });

    test('a closed leave ignores now entirely', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 4)), 7);
      expect(t.sickLeaveDaysAt(DateTime(2027, 1, 15)), 7);
    });
  });

  test('copyWith carries the sick-leave fields through', () {
    final t = _t(
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    );
    final ended = t.copyWith(
      isActive: false,
      sickLeaveTo: DateTime(2026, 3, 9),
    );
    expect(ended.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(ended.sickLeaveTo, DateTime(2026, 3, 9));
    expect(ended.sickLeaveRef, '1234567890');
    expect(ended.doctor, 'Dr. Rossi, Bozen');
    expect(ended.isActive, isFalse);
  });
}
