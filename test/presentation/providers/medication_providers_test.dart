import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
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

  Future<ProviderContainer> make({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (now != null) nowProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'expiringSoonProvider keeps expired items and sorts most urgent first',
    () async {
      final now = DateTime(2026, 3, 4, 15);
      final c = await make(now: now);
      final notifier = c.read(medicationListProvider.notifier);
      await c.read(medicationListProvider.future);

      Future<void> add(String name, int days, {bool archived = false}) =>
          notifier.addMedication(
            Medication(
              id: name,
              name: name,
              quantity: 1,
              isArchived: archived,
              // Calendar arithmetic, not absolute time: adding a
              // Duration shifts the date by one across a DST fall-back.
              expiryDate: DateTime(2026, 3, 4 + days),
            ),
          );

      await add('LongExpired', -40);
      await add('Expired', -1);
      await add('Today', 0);
      await add('Soon', 10);
      await add('Edge', 30);
      await add('Far', 31);
      await add('ArchivedExpired', -5, archived: true);
      await notifier.addMedication(
        const Medication(id: 'NoDate', name: 'NoDate', quantity: 1),
      );

      final soon = await c.read(expiringSoonProvider.future);
      expect(soon.map((m) => m.name).toList(), [
        'LongExpired',
        'Expired',
        'Today',
        'Soon',
        'Edge',
      ]);
    },
  );

  test('medications sharing an expiry date keep a stable order', () async {
    // Dart's List.sort is only stable up to 32 elements, and the comparator
    // has one key. A cabinet larger than that would reshuffle rows that share
    // an expiry date on every rebuild - visible jitter on a dashboard whose
    // whole job is to be glanced at.
    final now = DateTime(2026, 3, 4, 15);
    final c = await make(now: now);
    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);

    final names = [
      for (var i = 0; i < 40; i++) 'Med${i.toString().padLeft(2, '0')}',
    ];
    for (final name in names) {
      await notifier.addMedication(
        Medication(
          id: name,
          name: name,
          quantity: 1,
          expiryDate: DateTime(2026, 3, 10),
        ),
      );
    }

    final first = (await c.read(
      expiringSoonProvider.future,
    )).map((m) => m.name).toList();
    expect(first, names, reason: 'equal expiry dates must fall back to name');

    c.invalidate(expiringSoonProvider);
    final second = (await c.read(
      expiringSoonProvider.future,
    )).map((m) => m.name).toList();
    expect(second, first, reason: 'the order must not move between rebuilds');
  });

  test('one expired medication is not an empty expiry list', () async {
    // The dashboard's "All medications are within date" empty state keys off
    // this list being empty. With an expired box in the cabinet it must not
    // be, or the empty state is an actively false statement.
    final now = DateTime(2026, 3, 4, 15);
    final c = await make(now: now);
    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);
    await notifier.addMedication(
      Medication(
        id: 'a',
        name: 'Bentelan',
        quantity: 8,
        expiryDate: DateTime(2025, 12),
      ),
    );

    final soon = await c.read(expiringSoonProvider.future);
    expect(soon.single.name, 'Bentelan');
    expect(soon.single.expiredAt(now), isTrue);
  });

  test('mutations do not pass through a loading state', () async {
    final c = await make();
    await c.read(medicationListProvider.future);
    final states = <AsyncValue<List<Medication>>>[];
    final sub = c.listen(medicationListProvider, (_, next) => states.add(next));
    addTearDown(sub.close);

    await c
        .read(medicationListProvider.notifier)
        .addMedication(const Medication(id: 'x', name: 'X', quantity: 1));
    await c.read(medicationListProvider.notifier).updateQuantity('x', 2);

    expect(
      states.any((s) => s.isLoading && !s.hasValue),
      isFalse,
      reason: 'list flashed a spinner',
    );
    expect(states.last.value!.single.quantity, 3);
  });

  test('stock alerts follow the cabinet, not just the next launch', () async {
    final prefs = await SharedPreferences.getInstance();
    final port = FakePort();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        reminderPortProvider.overrideWithValue(port),
      ],
    );
    addTearDown(c.dispose);

    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);
    await notifier.addMedication(
      const Medication(id: 'x', name: 'X', quantity: 10, minimumStockLevel: 2),
    );
    await pumpEventQueue();
    expect(port.stockAlerts, isEmpty);

    // Taking the last dose runs through updateQuantity (auto-diminish). The
    // home screen shows the low-stock badge at once; the notification must
    // not wait for the next cold start.
    await notifier.updateQuantity('x', -9);
    await pumpEventQueue();
    expect(port.stockAlerts.map((a) => a.id), [
      stockAlertId('x', StockAlertKind.lowStock),
    ]);

    await notifier.deleteMedication('x');
    await pumpEventQueue();
    expect(port.cancelledStockAlerts, [
      stockAlertId('x', StockAlertKind.lowStock),
    ]);
  });

  test('a cloud pull re-plans the stock alerts', () async {
    final prefs = await SharedPreferences.getInstance();
    final port = FakePort();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        reminderPortProvider.overrideWithValue(port),
      ],
    );
    addTearDown(c.dispose);

    // Reading the stream provider is what installs the post-sync listener.
    c.read(syncStateStreamProvider);
    await c.read(medicationListProvider.future);

    // The row another device restocked — written underneath the notifier,
    // the way the sync service writes a pulled row.
    final db = await AppDatabase.instance.database;
    final ts = DateTime(2026).toIso8601String();
    await db.insert('medications', {
      'id': 'x',
      'name': 'Aspirin',
      'quantity': 0,
      'quantity_unit': 'tablets',
      'minimum_stock_level': 2,
      'is_archived': 0,
      'created_at': ts,
      'updated_at': ts,
      'sync_status': 'synced',
    });

    c.read(syncServiceProvider).debugSetStateForTest(SyncState.success);
    await pumpEventQueue();

    // Without this the phone still announces yesterday's stock until the
    // next cold start: the listener refreshes the cabinet but the plain
    // refresh() never reconciles.
    expect(port.stockAlerts.map((a) => a.id), [
      stockAlertId('x', StockAlertKind.lowStock),
    ]);
  });
}
