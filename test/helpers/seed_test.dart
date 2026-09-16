/// The seed helpers' midnight clamps.
///
/// Both helpers keep a seeded time on today's calendar day whatever the
/// wall-clock hour, and the suites that use them trust the seed to land on
/// the right side of `now`: [recentToday] strictly before it (the dose is
/// overdue), [laterToday] strictly after it (the dose is still to come).
/// The clamps only run in the minutes either side of midnight — exactly
/// when nobody is watching a suite go red — so they are pinned here rather
/// than left to the six suites that depend on them.
library;

import 'package:flutter_test/flutter_test.dart';

import 'seed.dart';

void main() {
  group('recentToday', () {
    test('subtracts the interval when it stays on today', () {
      expect(
        recentToday(DateTime(2026, 3, 4, 15, 20), minutes: 10),
        DateTime(2026, 3, 4, 15, 10),
      );
    });

    test('stays before now when the subtraction crosses midnight', () {
      // Thirty seconds past midnight: ten minutes earlier is yesterday, so
      // the clamp decides. A clamp landing *after* now seeds a dose in the
      // future, and every assertion built on it — "Overdue" above all —
      // fails for a sixty-second window, once a night.
      final now = DateTime(2026, 3, 4, 0, 0, 30);
      final seeded = recentToday(now, minutes: 10);

      expect(
        seeded.isBefore(now),
        isTrue,
        reason: '$seeded is not before $now',
      );
      expect(seeded.day, now.day, reason: '$seeded is not today');
    });

    test('never lands in the future at the first instant of the day', () {
      // At exactly 00:00:00.000 there is no time that is both earlier than
      // now and still today, so start-of-day is the honest answer: equal,
      // never after.
      final now = DateTime(2026, 3, 4);
      expect(recentToday(now, minutes: 10).isAfter(now), isFalse);
    });
  });

  group('laterToday', () {
    test('adds the interval when it stays on today', () {
      expect(
        laterToday(DateTime(2026, 3, 4, 15, 20), minutes: 90),
        DateTime(2026, 3, 4, 16, 50),
      );
    });

    test('stays after now when the addition crosses midnight', () {
      // The mirror image, and the same hazard: a seed clamped to 23:59 is
      // already in the past at 23:59:30, so a dose meant to be upcoming is
      // seeded as overdue.
      final now = DateTime(2026, 3, 4, 23, 59, 30);
      final seeded = laterToday(now);

      expect(seeded.isAfter(now), isTrue, reason: '$seeded is not after $now');
      expect(seeded.day, now.day, reason: '$seeded is not today');
    });
  });
}
