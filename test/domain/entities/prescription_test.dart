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
    startTime: startTime ?? DateTime(2026, 3, 1, 8, 0),
    scheduleType: scheduleType,
    scheduleTimes: scheduleTimes,
  );
}

void main() {
  group('fixed_interval', () {
    test(
      'generates durationDays * (24 / interval) doses starting at startTime',
      () {
        final times = _p(intervalHours: 8, durationDays: 2).scheduledDoseTimes;
        expect(times.length, 6);
        expect(times.first, DateTime(2026, 3, 1, 8, 0));
        expect(times.last, DateTime(2026, 3, 3, 0, 0));
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
      expect(_p(intervalHours: 8).dosesPerDay, 3);
      expect(_p(intervalHours: 7).dosesPerDay, 4);
    });
  });

  group('firstDayTimes', () {
    test('returns the first dosesPerDay scheduled times', () {
      final times = _p(
        intervalHours: 8,
        startTime: DateTime(2026, 3, 1, 8, 0),
      ).firstDayTimes();
      expect(times, [
        DateTime(2026, 3, 1, 8, 0),
        DateTime(2026, 3, 1, 16, 0),
        DateTime(2026, 3, 2, 0, 0),
      ]);
    });

    test('matches dosesPerDay for times_per_day schedules', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '12:00', '18:00'],
        startTime: DateTime(2026, 3, 1, 7, 0),
      ).firstDayTimes();
      expect(times, [
        DateTime(2026, 3, 1, 8, 0),
        DateTime(2026, 3, 1, 12, 0),
        DateTime(2026, 3, 1, 18, 0),
      ]);
    });
  });

  group('times_per_day', () {
    test('uses the given clock times on each day of the duration', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 3,
        startTime: DateTime(2026, 3, 1, 7, 0),
      ).scheduledDoseTimes;
      expect(times.length, 6);
      expect(times[0], DateTime(2026, 3, 1, 8, 0));
      expect(times[1], DateTime(2026, 3, 1, 20, 0));
      expect(times.last, DateTime(2026, 3, 3, 20, 0));
    });

    test(
      'skips times on the first day that are before startTime and continues until endTime',
      () {
        final times = _p(
          scheduleType: 'times_per_day',
          scheduleTimes: ['08:00', '20:00'],
          durationDays: 1,
          startTime: DateTime(2026, 3, 1, 12, 0),
        ).scheduledDoseTimes;
        expect(times, [
          DateTime(2026, 3, 1, 20, 0),
          DateTime(2026, 3, 2, 8, 0),
        ]);
      },
    );

    test('includes a time equal to startTime (minute precision)', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00'],
        durationDays: 1,
        startTime: DateTime(2026, 3, 1, 8, 0),
      ).scheduledDoseTimes;
      expect(times, [DateTime(2026, 3, 1, 8, 0)]);
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
}
