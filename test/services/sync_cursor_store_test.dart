import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('in-memory store round-trips, resets one table and clears', () async {
    final store = SyncCursorStore.inMemory();
    expect(await store.pullKey('medications'), isNull);
    await store.setPullKey('medications', const PullKey(812, 'm1'));
    await store.setPullKey('dose_logs', const PullKey(900));
    expect(await store.pullKey('medications'), const PullKey(812, 'm1'));
    await store.resetPullKey('medications');
    expect(await store.pullKey('medications'), isNull);
    expect(await store.pullKey('dose_logs'), const PullKey(900));
    await store.clear();
    expect(await store.pullKey('dose_logs'), isNull);
  });

  test('prefs store keeps keys under sync.pull_key.<table>, and clear() '
      'also drops the old timestamp cursors', () async {
    SharedPreferences.setMockInitialValues({
      'sync.last_pull_at.dose_logs': '2026-03-04T11:00:00.000Z',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = SyncCursorStore(prefs);
    await store.setPullKey('dose_logs', const PullKey(812, 'd|1'));
    expect(prefs.getString('sync.pull_key.dose_logs'), '812|d|1');
    expect(await store.pullKey('dose_logs'), const PullKey(812, 'd|1'));
    await store.clear();
    expect(prefs.getString('sync.pull_key.dose_logs'), isNull);
    expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
  });

  group('the "delete all data" generation this device applied', () {
    test('is kept per account, in memory', () async {
      final store = SyncCursorStore.inMemory();
      expect(await store.wipeSeen('u1'), isNull);
      await store.setWipeSeen('u1', 2);
      expect(await store.wipeSeen('u1'), 2);
      expect(await store.wipeSeen('u2'), isNull, reason: 'another account');
      await store.clear();
      expect(await store.wipeSeen('u1'), 2, reason: 'not a cursor');
      expect(store.hasLegacyCursors, isFalse);
    });

    test('is kept in prefs, outside the cursors; a 0.3.0 cursor is told '
        'apart', () async {
      SharedPreferences.setMockInitialValues({
        'sync.last_pull_at.medications': '2026-03-04T11:00:00.000Z',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = SyncCursorStore(prefs);
      expect(store.hasLegacyCursors, isTrue);
      await store.setWipeSeen('user|with|bars', 7);
      expect(prefs.getString(SyncCursorStore.wipeSeenKey), 'user|with|bars|7');
      expect(await store.wipeSeen('user|with|bars'), 7);
      await store.clear();
      expect(store.hasLegacyCursors, isFalse);
      expect(await store.wipeSeen('user|with|bars'), 7);
    });
  });

  group('pull repair (version 2)', () {
    Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('an upgraded device clears its cursors once and records the repair '
        'only when finished', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.medications': '2026-03-04T11:00:00.000Z',
        'sync.failed_row.medications/m1': '{}',
      });
      final store = SyncCursorStore(prefs);

      expect(await store.startPullRepair(), isTrue);
      expect(prefs.getString('sync.last_pull_at.medications'), isNull);
      expect(prefs.getString('sync.failed_row.medications/m1'), '{}');
      expect(prefs.getInt('sync.pull_repair.reset'), 2);
      expect(prefs.getInt('sync.pull_repair.done'), isNull);

      // Not finished: still due, but the keys a partial pull stored since
      // are kept.
      await store.setPullKey('medications', const PullKey(812));
      expect(await store.startPullRepair(), isTrue);
      expect(await store.pullKey('medications'), const PullKey(812));

      await store.finishPullRepair();
      expect(prefs.getInt('sync.pull_repair.done'), 2);
      expect(await store.startPullRepair(), isFalse);
      expect(await store.pullKey('medications'), const PullKey(812));
    });

    test('a device that finished the first repair runs this one', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.dose_logs': '2026-03-04T11:00:00.000Z',
        'sync.pull_repair.reset': 1,
        'sync.pull_repair.done': 1,
      });
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isTrue);
      expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
    });

    test('without any cursor there is nothing to repair', () async {
      final prefs = await prefsWith({});
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isFalse);
      expect(prefs.getInt('sync.pull_repair.done'), 2);
    });

    test('the markers outlive clear()', () async {
      final prefs = await prefsWith({'sync.pull_key.medications': '812|'});
      final store = SyncCursorStore(prefs);
      await store.startPullRepair();
      await store.finishPullRepair();
      await store.clear();
      expect(prefs.getInt('sync.pull_repair.done'), 2);
      expect(await store.startPullRepair(), isFalse);
    });

    test('an in-memory store has nothing an older build stored', () async {
      final store = SyncCursorStore.inMemory();
      await store.setPullKey('medications', const PullKey(1));
      expect(await store.startPullRepair(), isFalse);
      expect(await store.pullKey('medications'), const PullKey(1));
    });
  });
}
