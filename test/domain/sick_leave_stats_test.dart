import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/sick_leave_stats.dart';

/// A treatment carrying sick leave from [from] to [to] (null = still open).
Treatment _leave(String name, String? from, String? to, {String id = ''}) =>
    Treatment(
      id: id.isEmpty ? name : id,
      name: name,
      startDate: DateTime.parse('${from ?? '2026-01-01'} 00:00:00'),
      sickLeaveFrom: from == null ? null : DateTime.parse('$from 00:00:00'),
      sickLeaveTo: to == null ? null : DateTime.parse('$to 00:00:00'),
    );

DateTime _day(String iso) => DateTime.parse('$iso 00:00:00');

void main() {
  final now = _day('2026-06-15');

  group('the days of a year', () {
    test('a closed leave counts both ends', () {
      // A note "from Monday to Friday" is five days, not four.
      final days = sickDaysIn(2026, [
        _leave('Flu', '2026-03-02', '2026-03-06'),
      ], now: now);

      expect(days, hasLength(5));
      expect(days.contains(_day('2026-03-02')), isTrue);
      expect(days.contains(_day('2026-03-06')), isTrue);
      expect(days.contains(_day('2026-03-07')), isFalse);
    });

    test('two overlapping leaves count a shared day once', () {
      // The whole reason this is a set: summing the two lengths would say
      // 8 days off in a week that only holds 6.
      final days = sickDaysIn(2026, [
        _leave('Flu', '2026-03-02', '2026-03-06'),
        _leave('Back', '2026-03-04', '2026-03-07'),
      ], now: now);

      expect(days, hasLength(6));
    });

    test('back-to-back leaves do not double-count the join', () {
      final days = sickDaysIn(2026, [
        _leave('Flu', '2026-03-02', '2026-03-04'),
        _leave('Cough', '2026-03-04', '2026-03-05'),
      ], now: now);

      expect(days, hasLength(4));
    });

    test('an open leave counts up to now and no further', () {
      final days = sickDaysIn(2026, [
        _leave('Ongoing', '2026-06-13', null),
      ], now: now);

      expect(days, hasLength(3)); // 13th, 14th, 15th
      expect(days.contains(_day('2026-06-16')), isFalse);
    });

    test('an open leave that starts after now counts nothing', () {
      final days = sickDaysIn(2026, [
        _leave('Booked', '2026-08-01', null),
      ], now: now);

      expect(days, isEmpty);
    });

    test('a leave across New Year lands in both years', () {
      final treatments = [_leave('Flu', '2025-12-30', '2026-01-02')];

      expect(sickDaysIn(2025, treatments, now: now), hasLength(2));
      expect(sickDaysIn(2026, treatments, now: now), hasLength(2));
    });

    test('an inverted range contributes nothing rather than throwing', () {
      // Reachable from a synced or restored row the form never validated;
      // `sickLeaveDaysAt` already answers null for it.
      final days = sickDaysIn(2026, [
        _leave('Broken', '2026-03-06', '2026-03-02'),
      ], now: now);

      expect(days, isEmpty);
    });

    test('a treatment with no leave contributes nothing', () {
      expect(
        sickDaysIn(2026, [_leave('Vitamins', null, null)], now: now),
        isEmpty,
      );
    });

    test('the days are date-only, so a time of day cannot split one', () {
      final treatments = [
        Treatment(
          id: 'evening',
          name: 'Flu',
          startDate: _day('2026-03-02'),
          sickLeaveFrom: DateTime.parse('2026-03-02 22:30:00'),
          sickLeaveTo: DateTime.parse('2026-03-03 06:15:00'),
        ),
      ];

      final days = sickDaysIn(2026, treatments, now: now);
      expect(days, {_day('2026-03-02'), _day('2026-03-03')});
    });
  });

  group('the numbers over those days', () {
    test('an empty year says so rather than dividing by zero', () {
      final stats = SickLeaveStats.of(2026, const [], now: now);

      expect(stats.totalDays, 0);
      expect(stats.episodes, 0);
      expect(stats.longestEpisodeDays, 0);
      expect(stats.averageEpisodeDays, 0);
      expect(stats.isEmpty, isTrue);
      expect(stats.byMonth, everyElement(0));
    });

    test('total is the deduplicated day count, not the sum of episodes', () {
      final stats = SickLeaveStats.of(2026, [
        _leave('Flu', '2026-03-02', '2026-03-06'), // 5
        _leave('Back', '2026-03-04', '2026-03-07'), // 4, two shared
      ], now: now);

      expect(stats.totalDays, 6);
      expect(stats.episodes, 2, reason: 'overlapping leaves are still two');
      expect(stats.longestEpisodeDays, 5);
      expect(stats.averageEpisodeDays, closeTo(4.5, 0.001));
    });

    test('the months sum to the total', () {
      final stats = SickLeaveStats.of(2026, [
        _leave('Flu', '2026-01-30', '2026-02-02'),
        _leave('Cold', '2026-05-04', '2026-05-06'),
      ], now: now);

      expect(stats.byMonth[0], 2); // 30, 31 January
      expect(stats.byMonth[1], 2); // 1, 2 February
      expect(stats.byMonth[4], 3); // May
      expect(stats.byMonth.reduce((a, b) => a + b), stats.totalDays);
    });

    test('illnesses are ranked by their own days, longest first', () {
      final stats = SickLeaveStats.of(2026, [
        _leave('Flu', '2026-03-02', '2026-03-06'), // 5
        _leave('Back', '2026-03-04', '2026-03-07'), // 4
        _leave('Cold', '2026-05-04', '2026-05-04'), // 1
      ], now: now);

      expect(stats.byTreatment.map((e) => e.name), ['Flu', 'Back', 'Cold']);
      expect(stats.byTreatment.map((e) => e.days), [5, 4, 1]);
      // Overlap means these sum to more than the total: a shared day is
      // attributable to both illnesses, and the screen says "attributable".
      expect(
        stats.byTreatment.fold(0, (sum, e) => sum + e.days),
        greaterThan(stats.totalDays),
      );
    });

    test('two leaves of one illness are one line, two episodes', () {
      final stats = SickLeaveStats.of(2026, [
        _leave('Flu', '2026-01-05', '2026-01-06', id: 'a'),
        _leave('Flu', '2026-11-02', '2026-11-04', id: 'b'),
      ], now: now);

      expect(stats.byTreatment, hasLength(1));
      expect(stats.byTreatment.single.days, 5);
      expect(stats.episodes, 2);
    });

    test('only the part inside the year counts towards its episodes', () {
      // The leave is 4 days over two years; 2026 owns two of them.
      final stats = SickLeaveStats.of(2026, [
        _leave('Flu', '2025-12-30', '2026-01-02'),
      ], now: now);

      expect(stats.totalDays, 2);
      expect(stats.episodes, 1);
      expect(stats.longestEpisodeDays, 2);
    });

    test('the first year with any leave is where the stepper stops', () {
      final treatments = [
        _leave('Old', '2023-02-01', '2023-02-03'),
        _leave('New', '2026-02-01', '2026-02-03'),
        _leave('None', null, null),
      ];

      expect(firstSickLeaveYear(treatments), 2023);
      expect(firstSickLeaveYear(const []), isNull);
    });
  });
}
