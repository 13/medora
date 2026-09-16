import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/register_freshness.dart';

void main() {
  final now = DateTime(2026, 9, 16, 10);

  test('the source date wins over the sync date', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: DateTime(2026, 9, 1),
      lastSync: DateTime(2026, 9, 15),
      count: 100,
    );
    expect(f.days, 15);
    expect(f.isStale, isFalse);
    expect(f.isMissing, isFalse);
  });

  test('without a source date the sync date is used', () {
    final f = registerFreshness(
      now: now,
      lastSync: DateTime(2026, 7, 1),
      count: 100,
    );
    expect(f.days, 77);
    expect(f.isStale, isTrue);
  });

  test('exactly 45 days is stale', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: now.subtract(const Duration(days: 45)),
      count: 1,
    );
    expect(f.days, 45);
    expect(f.isStale, isTrue);
  });

  test('44 days is not stale', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: now.subtract(const Duration(days: 44)),
      count: 1,
    );
    expect(f.isStale, isFalse);
  });

  test('nothing cached is missing, not stale', () {
    final f = registerFreshness(now: now);
    expect(f.isMissing, isTrue);
    expect(f.isStale, isFalse);
    expect(f.days, isNull);
  });

  test('rows cached but no date at all counts as stale', () {
    final f = registerFreshness(now: now, count: 100);
    expect(f.isMissing, isFalse);
    expect(f.isStale, isTrue);
    expect(f.days, isNull);
  });

  test('days ignore the time of day', () {
    final f = registerFreshness(
      now: DateTime(2026, 9, 16, 23, 59),
      sourceUpdated: DateTime(2026, 9, 15, 0, 1),
      count: 1,
    );
    expect(f.days, 1);
  });
}
