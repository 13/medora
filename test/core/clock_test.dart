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
}
