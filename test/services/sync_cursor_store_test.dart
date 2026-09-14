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
}
