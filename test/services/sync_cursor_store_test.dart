import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('in-memory store round-trips and clears', () async {
    final store = SyncCursorStore.inMemory();
    expect(await store.lastPullAt('medications'), isNull);
    final t = DateTime.utc(2026, 3, 4, 15);
    await store.setLastPullAt('medications', t);
    expect(await store.lastPullAt('medications'), t);
    await store.clear();
    expect(await store.lastPullAt('medications'), isNull);
  });

  test(
    'prefs store persists under sync.last_pull_at.<table> as UTC ISO',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = SyncCursorStore(prefs);
      await store.setLastPullAt(
        'dose_logs',
        DateTime(2026, 3, 4, 16, 30),
      ); // local time in
      final raw = prefs.getString('sync.last_pull_at.dose_logs');
      expect(raw, endsWith('Z'));
      expect(
        await store.lastPullAt('dose_logs'),
        DateTime(2026, 3, 4, 16, 30).toUtc(),
      );
      await store.clear();
      expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
    },
  );

  group('pull repair', () {
    Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('with stored cursors it clears them once and is recorded only when '
        'finished', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.medications': '2026-03-04T11:00:00.000Z',
        'sync.failed_row.medications/m1': '{}',
      });
      final store = SyncCursorStore(prefs);

      expect(await store.startPullRepair(), isTrue);
      expect(await store.lastPullAt('medications'), isNull);
      expect(prefs.getString('sync.failed_row.medications/m1'), '{}');
      expect(prefs.getInt('sync.pull_repair.reset'), 1);
      expect(prefs.getInt('sync.pull_repair.done'), isNull);

      // Not finished: still due, but the cursors a partial pull stored
      // since are kept.
      await store.setLastPullAt('medications', DateTime.utc(2026, 3, 4, 12));
      expect(await store.startPullRepair(), isTrue);
      expect(
        await store.lastPullAt('medications'),
        DateTime.utc(2026, 3, 4, 12),
      );

      await store.finishPullRepair();
      expect(prefs.getInt('sync.pull_repair.done'), 1);
      expect(await store.startPullRepair(), isFalse);
      expect(
        await store.lastPullAt('medications'),
        DateTime.utc(2026, 3, 4, 12),
      );
    });

    test('a later repair version runs again', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.dose_logs': '2026-03-04T11:00:00.000Z',
        'sync.pull_repair.reset': 0,
        'sync.pull_repair.done': 0,
      });
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isTrue);
      expect(await store.lastPullAt('dose_logs'), isNull);
    });

    test('without any cursor there is nothing to repair', () async {
      final prefs = await prefsWith({});
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isFalse);
      expect(prefs.getInt('sync.pull_repair.done'), 1);
    });

    test('the markers outlive clear()', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.medications': '2026-03-04T11:00:00.000Z',
      });
      final store = SyncCursorStore(prefs);
      await store.startPullRepair();
      await store.finishPullRepair();
      await store.clear();
      expect(prefs.getInt('sync.pull_repair.done'), 1);
      expect(await store.startPullRepair(), isFalse);
    });

    test('an in-memory store has nothing an older build stored', () async {
      final store = SyncCursorStore.inMemory();
      await store.setLastPullAt('medications', DateTime.utc(2026));
      expect(await store.startPullRepair(), isFalse);
      expect(await store.lastPullAt('medications'), DateTime.utc(2026));
    });
  });
}
