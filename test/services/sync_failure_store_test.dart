import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime.utc(2026, 3, 4, 12);

  group('SyncRowFailure', () {
    test('backoff doubles per failure and caps at 6 h', () {
      Duration backoffAfter(int count) =>
          SyncRowFailure(count: count, lastAttempt: t0).backoff;
      expect(backoffAfter(1), const Duration(minutes: 2));
      expect(backoffAfter(2), const Duration(minutes: 4));
      expect(backoffAfter(3), const Duration(minutes: 8));
      expect(backoffAfter(8), const Duration(minutes: 256));
      expect(backoffAfter(9), const Duration(hours: 6));
      expect(backoffAfter(40), const Duration(hours: 6));
    });

    test('isBackingOffAt is false once the backoff has elapsed', () {
      final f = SyncRowFailure(count: 1, lastAttempt: t0);
      expect(f.isBackingOffAt(t0.add(const Duration(minutes: 1))), isTrue);
      expect(f.isBackingOffAt(t0.add(const Duration(minutes: 2))), isFalse);
      expect(f.isBackingOffAt(t0.add(const Duration(minutes: 3))), isFalse);
    });
  });

  group('SyncFailureStore', () {
    test('in-memory store counts consecutive failures and clears', () async {
      final store = SyncFailureStore.inMemory();
      expect(await store.get('medications', 'm1'), isNull);

      final first = await store.recordFailure('medications', 'm1', t0);
      expect(first.count, 1);
      expect(first.lastAttempt, t0);

      final second = await store.recordFailure(
        'medications',
        'm1',
        t0.add(const Duration(minutes: 5)),
      );
      expect(second.count, 2);
      expect((await store.get('medications', 'm1'))?.count, 2);

      await store.clear('medications', 'm1');
      expect(await store.get('medications', 'm1'), isNull);
    });

    test('rows of different tables do not collide', () async {
      final store = SyncFailureStore.inMemory();
      await store.recordFailure('medications', 'x', t0);
      expect(await store.get('dose_logs', 'x'), isNull);
    });

    test('the prefs-backed store round-trips and clearAll wipes', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = SyncFailureStore(prefs);

      await store.recordFailure('treatments', 't1', t0);
      await store.recordFailure('treatments', 't1', t0);
      final read = await SyncFailureStore(prefs).get('treatments', 't1');
      expect(read?.count, 2);
      expect(read?.lastAttempt, t0);

      await store.clearAll();
      expect(await store.get('treatments', 't1'), isNull);
      expect(
        prefs.getKeys().where((k) => k.startsWith(SyncFailureStore.keyPrefix)),
        isEmpty,
      );
    });

    test('a corrupt stored value reads back as null', () async {
      SharedPreferences.setMockInitialValues({
        '${SyncFailureStore.keyPrefix}medications/broken': 'not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        await SyncFailureStore(prefs).get('medications', 'broken'),
        isNull,
      );
    });
  });
}
