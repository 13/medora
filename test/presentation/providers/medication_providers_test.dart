import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/stock_expiry_reminders.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<ProviderContainer> make() async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'expiringSoonProvider lists only unexpired items within 30 days',
    () async {
      final c = await make();
      final notifier = c.read(medicationListProvider.notifier);
      await c.read(medicationListProvider.future);
      final today = DateTime.now();
      await notifier.addMedication(
        Medication(
          id: 'a',
          name: 'Expired',
          quantity: 1,
          expiryDate: today.subtract(const Duration(days: 1)),
        ),
      );
      await notifier.addMedication(
        Medication(
          id: 'b',
          name: 'Soon',
          quantity: 1,
          expiryDate: today.add(const Duration(days: 10)),
        ),
      );
      await notifier.addMedication(
        Medication(
          id: 'c',
          name: 'Far',
          quantity: 1,
          expiryDate: today.add(const Duration(days: 90)),
        ),
      );

      final soon = await c.read(expiringSoonProvider.future);
      expect(soon.map((m) => m.name).toList(), ['Soon']);
    },
  );

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
}
