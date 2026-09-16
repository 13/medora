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

    test('a start later in the day than now still counts that day', () {
      // Unlike the midnight cases above, a plain Duration count gets this
      // wrong in every time zone (1 day 14 hours floors to 1, so 2 days).
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3, 18));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5, 8)), 3);
    });

    test('a closed leave ending earlier in the day than it began', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3, 18),
        sickLeaveTo: DateTime(2026, 3, 9, 8),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), 7);
    });

    test('a leave that ends before it starts has no count', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 9),
        sickLeaveTo: DateTime(2026, 3, 3),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), isNull);
    });

    test('a leave ending the day before it starts has no count', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 2, 23, 59),
      );
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 20)), isNull);
    });

    test('an open leave that has not started yet has no count', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 10));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 5)), isNull);
      // The day before, even late in the evening, is still "not yet".
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 9, 23, 59)), isNull);
    });

    test('an open leave starting today is day one', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 10, 9));
      expect(t.sickLeaveDaysAt(DateTime(2026, 3, 10, 7)), 1);
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

  group('sickLeaveEndAt', () {
    test('an open leave ends on the calendar date of now', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 3));
      expect(
        t.sickLeaveEndAt(DateTime(2026, 3, 12, 18, 30)),
        DateTime(2026, 3, 12),
      );
    });

    test('a leave that started today ends today, even if its start carries '
        'a later time of day', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 12, 20));
      expect(t.sickLeaveEndAt(DateTime(2026, 3, 12, 7)), DateTime(2026, 3, 12));
    });

    test('there is nothing to end without a leave', () {
      expect(_t().sickLeaveEndAt(DateTime(2026, 3, 12)), isNull);
    });

    test('a closed leave is never moved', () {
      final t = _t(
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
      );
      expect(t.sickLeaveEndAt(DateTime(2026, 3, 12)), isNull);
    });

    test('an open leave that has not started yet is not ended', () {
      final t = _t(sickLeaveFrom: DateTime(2026, 3, 13));
      expect(t.sickLeaveEndAt(DateTime(2026, 3, 12, 23, 59)), isNull);
    });
  });

  group('copyWith', () {
    final base = _t(
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    );

    test('keeps the sick-leave fields it is not given', () {
      final ended = base.copyWith(isActive: false);
      expect(ended.sickLeaveFrom, DateTime(2026, 3, 3));
      expect(ended.sickLeaveTo, isNull);
      expect(ended.sickLeaveRef, '1234567890');
      expect(ended.doctor, 'Dr. Rossi, Bozen');
      expect(ended.isActive, isFalse);
    });

    test('replaces every sick-leave field it is given', () {
      final edited = base.copyWith(
        sickLeaveFrom: DateTime(2026, 3, 4),
        sickLeaveTo: DateTime(2026, 3, 9),
        sickLeaveRef: '0987654321',
        doctor: 'Dr. Bianchi, Meran',
      );
      expect(edited.sickLeaveFrom, DateTime(2026, 3, 4));
      expect(edited.sickLeaveTo, DateTime(2026, 3, 9));
      expect(edited.sickLeaveRef, '0987654321');
      expect(edited.doctor, 'Dr. Bianchi, Meran');
      expect(edited.name, base.name);
      expect(edited.startDate, base.startDate);
    });
  });
}
