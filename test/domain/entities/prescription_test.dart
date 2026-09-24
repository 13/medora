import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/prescription.dart';

Prescription _p({
  int intervalHours = 8,
  int durationDays = 7,
  DateTime? startTime,
  String scheduleType = 'fixed_interval',
  List<String>? scheduleTimes,
}) {
  return Prescription(
    id: 'p1',
    treatmentId: 't1',
    medicationId: 'm1',
    dosage: '1 tablet',
    intervalHours: intervalHours,
    durationDays: durationDays,
    startTime: startTime ?? DateTime(2026, 3, 1, 8),
    scheduleType: scheduleType,
    scheduleTimes: scheduleTimes,
  );
}

void main() {
  group('fixed_interval', () {
    test(
      'generates durationDays * (24 / interval) doses starting at startTime',
      () {
        final times = _p(durationDays: 2).scheduledDoseTimes;
        expect(times.length, 6);
        expect(times.first, DateTime(2026, 3, 1, 8));
        expect(times.last, DateTime(2026, 3, 3));
      },
    );

    test('is sorted ascending and strictly before endTime', () {
      final p = _p(intervalHours: 6, durationDays: 3);
      final times = p.scheduledDoseTimes;
      for (var i = 1; i < times.length; i++) {
        expect(times[i].isAfter(times[i - 1]), isTrue);
      }
      expect(times.every((t) => t.isBefore(p.endTime)), isTrue);
    });

    test('clamps interval below 1 hour to 1 hour (no infinite loop)', () {
      final times = _p(intervalHours: 0, durationDays: 1).scheduledDoseTimes;
      expect(times.length, 24);
    });

    test('caps at 1000 doses for absurd durations', () {
      final times = _p(intervalHours: 1, durationDays: 365).scheduledDoseTimes;
      expect(times.length, 1000);
    });

    test('dosesPerDay rounds up', () {
      expect(_p().dosesPerDay, 3);
      expect(_p(intervalHours: 7).dosesPerDay, 4);
    });
  });

  group('previewTimes', () {
    test('returns the first dosesPerDay scheduled times', () {
      final times = _p(startTime: DateTime(2026, 3, 1, 8)).previewTimes();
      expect(times, [
        DateTime(2026, 3, 1, 8),
        DateTime(2026, 3, 1, 16),
        DateTime(2026, 3, 2),
      ]);
    });

    test('matches dosesPerDay for times_per_day schedules', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '12:00', '18:00'],
        startTime: DateTime(2026, 3, 1, 7),
      ).previewTimes();
      expect(times, [
        DateTime(2026, 3, 1, 8),
        DateTime(2026, 3, 1, 12),
        DateTime(2026, 3, 1, 18),
      ]);
    });
  });

  group('times_per_day', () {
    test('uses the given clock times on each day of the duration', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 3,
        startTime: DateTime(2026, 3, 1, 7),
      ).scheduledDoseTimes;
      expect(times.length, 6);
      expect(times[0], DateTime(2026, 3, 1, 8));
      expect(times[1], DateTime(2026, 3, 1, 20));
      expect(times.last, DateTime(2026, 3, 3, 20));
    });

    test(
      'skips times on the first day that are before startTime and continues until endTime',
      () {
        final times = _p(
          scheduleType: 'times_per_day',
          scheduleTimes: ['08:00', '20:00'],
          durationDays: 1,
          startTime: DateTime(2026, 3, 1, 12),
        ).scheduledDoseTimes;
        expect(times, [DateTime(2026, 3, 1, 20), DateTime(2026, 3, 2, 8)]);
      },
    );

    test('includes a time equal to startTime (minute precision)', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00'],
        durationDays: 1,
        startTime: DateTime(2026, 3, 1, 8),
      ).scheduledDoseTimes;
      expect(times, [DateTime(2026, 3, 1, 8)]);
    });

    test('falls back to fixed interval when scheduleTimes is empty', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: const [],
        intervalHours: 12,
        durationDays: 1,
      ).scheduledDoseTimes;
      expect(times.length, 2);
    });

    test('dosesPerDay equals number of times', () {
      expect(
        _p(
          scheduleType: 'times_per_day',
          scheduleTimes: ['08:00', '12:00', '18:00'],
        ).dosesPerDay,
        3,
      );
    });
  });

  group('as_needed', () {
    test('generates no scheduled doses', () {
      expect(_p(scheduleType: 'as_needed').scheduledDoseTimes, isEmpty);
    });

    test('dosesPerDay is zero', () {
      expect(_p(scheduleType: 'as_needed').dosesPerDay, 0);
    });

    test('previewTimes is empty', () {
      expect(_p(scheduleType: 'as_needed').previewTimes(), isEmpty);
    });

    test('ignores interval, duration and leftover times entirely', () {
      // The sheet hides these fields for an as-needed prescription but keeps
      // their stored values, e.g. after switching from another schedule.
      final p = _p(
        scheduleType: 'as_needed',
        intervalHours: 4,
        durationDays: 30,
        scheduleTimes: ['08:00', '20:00'],
      );
      expect(p.scheduledDoseTimes, isEmpty);
      expect(p.dosesPerDay, 0);
    });
  });

  group('unitsPerDose', () {
    Prescription dose(String dosage, {double? amount, String? unit}) =>
        Prescription(
          id: 'p1',
          treatmentId: 't1',
          medicationId: 'm1',
          dosage: dosage,
          dosageAmount: amount,
          dosageUnit: unit,
          startTime: DateTime(2026, 3, 1, 8),
        );

    test('"400 mg" of ibuprofen is one tablet, with or without a unit', () {
      expect(dose('400 mg').unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('400 mg').unitsPerDose(), 1);
      expect(dose('400mg').unitsPerDose(medicationUnit: ''), 1);
      expect(dose('400 mg ibuprofen').unitsPerDose(), 1);
    });

    test('an amount in the medication\'s own unit is counted', () {
      expect(
        dose('2 tablets', amount: 2).unitsPerDose(medicationUnit: 'tablets'),
        2,
      );
      expect(
        dose(
          '2 tablets',
          amount: 2,
          unit: 'tablets',
        ).unitsPerDose(medicationUnit: 'tablets'),
        2,
      );
      expect(dose('5 ml', amount: 5).unitsPerDose(medicationUnit: 'ml'), 5);
      expect(dose('', amount: 1.5).unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('', amount: 0.25).unitsPerDose(medicationUnit: 'tablets'), 0);
    });

    test('an amount in another unit is one pack unit', () {
      expect(dose('2 capsules').unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('2 x 500 mg').unitsPerDose(medicationUnit: 'tablets'), 1);
    });

    test('drops from a stock in ml count twenty to the millilitre, rounded '
        'down', () {
      expect(
        dose(
          '20 drops',
          amount: 20,
          unit: 'drops',
        ).unitsPerDose(medicationUnit: 'ml'),
        1,
      );
      expect(dose('40 gocce').unitsPerDose(medicationUnit: 'ml'), 2);
      expect(dose('5 gocce').unitsPerDose(medicationUnit: 'ml'), 0);
      expect(dose('30 Tropfen').unitsPerDose(medicationUnit: 'ml'), 1);
    });

    test('a volume never takes a counted pack unit', () {
      // A syrup or drops kept as bottles, pieces or without a unit: one dose
      // is not a whole bottle.
      for (final stock in [null, '', 'pieces', 'tablets', 'bustine']) {
        expect(
          dose(
            '5 ml',
            amount: 5,
            unit: 'ml',
          ).unitsPerDose(medicationUnit: stock),
          0,
          reason: '$stock',
        );
        expect(dose('10 ml').unitsPerDose(medicationUnit: stock), 0);
        expect(dose('20 Tropfen').unitsPerDose(medicationUnit: stock), 0);
      }
      expect(dose('5 ml').unitsPerDose(medicationUnit: 'drops'), 0);
    });

    test('a fraction is rounded down, never up', () {
      expect(dose('0,5 compresse').unitsPerDose(), 0);
      expect(dose('1,5 cpr').unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('', amount: 0.5).unitsPerDose(medicationUnit: 'tablets'), 0);
      expect(dose('½ compressa').unitsPerDose(medicationUnit: 'tablets'), 0);
      expect(dose('1/2 Tablette').unitsPerDose(medicationUnit: 'tablets'), 0);
      expect(dose('3/2 Tabletten').unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('2,75 ml').unitsPerDose(medicationUnit: 'ml'), 2);
    });

    test('pieces, pills and tablets count the same things', () {
      expect(dose('2 Tabletten').unitsPerDose(medicationUnit: 'pieces'), 2);
      expect(dose('2 pills').unitsPerDose(medicationUnit: 'tablets'), 2);
      expect(dose('3 Stück').unitsPerDose(medicationUnit: 'pills'), 3);
      expect(dose('2 capsules').unitsPerDose(medicationUnit: 'pieces'), 1);
    });

    test('the Italian abbreviations cp and cps are counted', () {
      expect(dose('2 cp').unitsPerDose(medicationUnit: 'tablets'), 2);
      expect(dose('2 cps').unitsPerDose(medicationUnit: 'capsules'), 2);
    });

    test('an amount with no unit anywhere is a count', () {
      expect(dose('', amount: 2).unitsPerDose(), 2);
      expect(dose('2').unitsPerDose(), 2);
    });

    test('free text in a counting unit is counted, in any language', () {
      for (final text in [
        '2 tablets',
        '2 Tabletten',
        '2 compresse',
        '2 cpr.',
      ]) {
        expect(dose(text).unitsPerDose(), 2, reason: text);
        expect(
          dose(text).unitsPerDose(medicationUnit: 'tablets'),
          2,
          reason: text,
        );
      }
      expect(dose('1 tablet').unitsPerDose(medicationUnit: 'tablets'), 1);
      expect(dose('3 Kapseln').unitsPerDose(medicationUnit: 'capsules'), 3);
      expect(dose('2 Stück').unitsPerDose(), 2);
      expect(dose('2,0 ml').unitsPerDose(medicationUnit: 'ml'), 2);
    });

    test('free text without a count, or in a unit that is not counted, is '
        'one pack unit', () {
      expect(dose('one tablet').unitsPerDose(), 1);
      expect(dose('').unitsPerDose(), 1);
      expect(dose('400 mg').unitsPerDose(medicationUnit: 'ml'), 1);
      expect(dose('20 Tropfen').unitsPerDose(medicationUnit: 'drops'), 20);
    });
  });

  // Europe/Rome (the zone the suite runs in) moves to summer time on
  // 2026-03-29 and 2027-03-28 and back on 2026-10-25. In a zone without DST
  // these pass trivially.
  group('daylight saving time', () {
    Map<DateTime, int> perDay(List<DateTime> times) {
      final counts = <DateTime, int>{};
      for (final t in times) {
        final day = DateTime(t.year, t.month, t.day);
        counts[day] = (counts[day] ?? 0) + 1;
      }
      return counts;
    }

    test('endTime keeps the wall-clock time across a DST change', () {
      final p = _p(durationDays: 365, startTime: DateTime(2026, 3, 28, 8));
      expect(p.endTime, DateTime(2027, 3, 28, 8));
      final autumn = _p(startTime: DateTime(2026, 10, 22, 8));
      expect(autumn.endTime, DateTime(2026, 10, 29, 8));
    });

    test('endTime of a UTC start stays UTC', () {
      final p = _p(durationDays: 2, startTime: DateTime.utc(2026, 3, 28, 8));
      expect(p.endTime, DateTime.utc(2026, 3, 30, 8));
      expect(p.endTime.isUtc, isTrue);
    });

    test('a year from the day before spring forward has one dose per time '
        'per day', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 365,
        startTime: DateTime(2026, 3, 28, 8),
      ).scheduledDoseTimes;
      expect(times.length, 365 * 2);
      expect(times.first, DateTime(2026, 3, 28, 8));
      expect(times.last, DateTime(2027, 3, 27, 20));
      final days = perDay(times);
      expect(days.length, 365);
      expect(days.values.every((n) => n == 2), isTrue);
      expect(days[DateTime(2026, 10, 25)], 2);
      expect(times.toSet().length, times.length);
    });

    test('a year from the summer visits each day once, the change days '
        'included', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 365,
        startTime: DateTime(2026, 6, 1, 8),
      ).scheduledDoseTimes;
      expect(times.length, 365 * 2);
      final days = perDay(times);
      expect(days.length, 365);
      expect(days[DateTime(2026, 10, 25)], 2);
      expect(days[DateTime(2027, 3, 28)], 2);
      expect(times.toSet().length, times.length);
    });

    test('a fixed interval steps in elapsed hours across a DST change', () {
      final times = _p(
        intervalHours: 12,
        durationDays: 3,
        startTime: DateTime(2026, 3, 28, 8),
      ).scheduledDoseTimes;
      // 08:00 CET plus 24 hours is 09:00 CEST.
      expect(times[2], DateTime(2026, 3, 29, 9));
    });
  });

  test('a zero duration generates nothing, whatever the type is read as', () {
    // An older build reads 'as_needed' as a fixed interval: with the zero
    // duration an as-needed prescription is saved with, that is no dose.
    for (final type in ['fixed_interval', 'as_needed', 'a_future_type']) {
      expect(
        _p(durationDays: 0, scheduleType: type).scheduledDoseTimes,
        isEmpty,
        reason: type,
      );
    }
    expect(
      _p(
        durationDays: 0,
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
      ).scheduledDoseTimes,
      isEmpty,
    );
  });
}
