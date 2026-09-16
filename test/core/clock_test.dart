import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/clock.dart';

void main() {
  group('nextUpdatedAt', () {
    final previous = DateTime.utc(2026, 3, 4, 12);

    test('uses now when it is ahead of the previous stamp', () {
      final now = previous.add(const Duration(seconds: 5));
      expect(nextUpdatedAt(previous, now), now);
    });

    test('uses now when there is no previous stamp', () {
      expect(nextUpdatedAt(null, previous), previous);
    });

    test('steps one millisecond past a clock that went backwards', () {
      final now = previous.subtract(const Duration(minutes: 10));
      expect(
        nextUpdatedAt(previous, now),
        previous.add(const Duration(milliseconds: 1)),
      );
    });

    test('steps past a second write inside the same millisecond', () {
      expect(
        nextUpdatedAt(previous, previous),
        previous.add(const Duration(milliseconds: 1)),
      );
    });

    test('compares across time zones', () {
      final localPrevious = previous.toLocal();
      final now = previous.subtract(const Duration(hours: 1));
      expect(
        nextUpdatedAt(localPrevious, now),
        localPrevious.add(const Duration(milliseconds: 1)),
      );
    });
  });

  group('parseWallClock', () {
    test('keeps the digits, whatever offset the server added', () {
      for (final raw in [
        '2026-03-01T08:30:00',
        '2026-03-01T08:30:00.000',
        '2026-03-01T08:30:00Z',
        '2026-03-01T08:30:00.000Z',
        '2026-03-01T08:30:00+00:00',
        '2026-03-01T08:30:00+02:00',
        '2026-03-01T08:30:00-05',
        '2026-03-01 08:30:00+0100',
      ]) {
        final parsed = parseWallClock(raw);
        expect(parsed, DateTime(2026, 3, 1, 8, 30), reason: raw);
        expect(parsed.isUtc, isFalse, reason: raw);
      }
    });

    test('reads a date alone as local midnight', () {
      expect(parseWallClock('2026-03-02'), DateTime(2026, 3, 2));
    });

    test('wallClockString writes the digits without an offset', () {
      expect(
        wallClockString(DateTime.utc(2026, 3, 1, 8, 30)),
        '2026-03-01T08:30:00.000',
      );
      expect(
        parseWallClock(wallClockString(DateTime(2026, 10, 25, 2, 30))),
        DateTime(2026, 10, 25, 2, 30),
      );
    });
  });
}
