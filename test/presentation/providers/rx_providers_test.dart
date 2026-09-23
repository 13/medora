import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  test('a sync re-reads the prescriptions and persons on screen', () async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        reminderPortProvider.overrideWithValue(FakePort()),
      ],
    );
    addTearDown(c.dispose);
    // Reading the stream provider is what installs the post-sync listener.
    c.read(syncStateStreamProvider);
    c.listen(rxListProvider, (_, _) {});
    c.listen(personsProvider, (_, _) {});
    expect(await c.read(rxListProvider.future), isEmpty);
    expect(await c.read(personsProvider.future), isEmpty);

    // Rows another device made, written underneath the providers the way
    // the sync service writes a pulled row.
    final db = await AppDatabase.instance.database;
    const ts = '2026-03-04T12:00:00.000Z';
    await db.insert('persons', {
      'id': 'p1',
      'name': 'Ben',
      'exemptions': '[]',
      'created_at': ts,
      'updated_at': ts,
      'sync_status': 'synced',
    });
    await db.insert('rx', {
      'id': 'r1',
      'person_id': 'p1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[]',
      'cancelled': 0,
      'created_at': ts,
      'updated_at': ts,
      'sync_status': 'synced',
    });

    c.read(syncServiceProvider).debugSetStateForTest(SyncState.success);
    await pumpEventQueue();

    expect((await c.read(rxListProvider.future)).single.rx.id, 'r1');
    expect((await c.read(personsProvider.future)).single.name, 'Ben');
  });
}
