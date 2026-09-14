import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final sub = c.listen(
      medicationListProvider,
      (_, next) => states.add(next),
      fireImmediately: false,
    );
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
}
