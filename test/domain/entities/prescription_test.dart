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
}
