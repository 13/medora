import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
  ];

  testWidgets('shows three sections and saves a medication with just a name', (
    tester,
  ) async {
    final c = await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FormSection), findsNWidgets(3));
    expect(find.text('Basics'), findsOneWidget);
    expect(find.text('Stock & storage'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Medication Name *').first,
      'Moment',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();

    final list = await c.read(medicationListProvider.future);
    expect(list.map((m) => m.name), ['Moment']);
  });

  testWidgets('empty name shows the validator and keeps Basics expanded', (
    tester,
  ) async {
    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a medication name'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Medication Name *'),
      findsOneWidget,
    ); // still visible ⇒ section expanded
  });

  testWidgets(
    'collapsing Basics does not bypass validation and the section reopens on error',
    (tester) async {
      final c = await pumpMedoraApp(
        tester,
        const AddMedicationScreen(),
        overrides: await overrides(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Basics'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a medication name'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Medication Name *'),
        findsOneWidget,
      );

      // Collapse Basics again (now auto-expanded from the error above), then
      // save again: the section must still reopen and show the error, proving
      // the manual collapse wrote back into the controller.
      await tester.tap(find.text('Basics'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a medication name'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'Medication Name *'),
        findsOneWidget,
      );

      final list = await c.read(medicationListProvider.future);
      expect(list, isEmpty);
    },
  );

  testWidgets('collapsed Stock section shows a summary', (tester) async {
    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('min 0'), findsOneWidget);

    // The header sits below the fold on the 800x600 default viewport once
    // the quick-action chips wrap onto a second line.
    await tester.ensureVisible(find.text('Stock & storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stock & storage'));
    await tester.pumpAndSettle();

    expect(find.textContaining('min 0'), findsNothing);
  });

  group('editing a medication in cloud mode', () {
    Future<List<Override>> cloud() async => [
      ...await overrides(),
      medicationRepositoryProvider.overrideWithValue(
        MedicationRepositoryImpl(
          localDatasource: MedicationLocalDatasource(),
          requestSync: () async {},
          newOpId: () => 'op-${DateTime.now().microsecondsSinceEpoch}',
        ),
      ),
    ];

    Future<void> seed() => MedicationLocalDatasource().upsert(
      const MedicationModel(id: 'm1', name: 'Moment', quantity: 10),
      syncStatus: SyncStatus.synced,
    );

    Future<Map<String, Object?>> stored() async =>
        (await (await AppDatabase.instance.database).query(
          'medications',
        )).single;

    Future<List<(int?, int?)>> changes() async => [
      for (final op in await StockOutboxLocalDatasource().pending())
        (op.delta, op.setTo),
    ];

    Future<void> save(WidgetTester tester) async {
      final button = find.widgetWithText(FilledButton, 'Update Medication');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('a quantity left as it was loaded keeps a dose taken since '
        'the form opened', (tester) async {
      await seed();
      final c = await pumpMedoraApp(
        tester,
        const AddMedicationScreen(medicationId: 'm1'),
        overrides: await cloud(),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '10'), findsOneWidget);
      // A dose taken meanwhile (from a reminder, or pulled from another
      // phone).
      await c.read(medicationRepositoryProvider).updateQuantity('m1', -1);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Medication Name *').first,
        'Moment Act',
      );
      await save(tester);

      final row = await stored();
      expect([row['name'], row['quantity']], ['Moment Act', 9]);
      expect(await changes(), [(-1, null)]);
    });

    testWidgets('a quantity typed in goes out as a count', (tester) async {
      await seed();
      await pumpMedoraApp(
        tester,
        const AddMedicationScreen(medicationId: 'm1'),
        overrides: await cloud(),
      );
      await tester.pumpAndSettle();

      final field = find.widgetWithText(TextFormField, '10');
      await tester.ensureVisible(field);
      await tester.enterText(field, '12');
      await save(tester);

      expect((await stored())['quantity'], 12);
      expect(await changes(), [(null, 12)]);
    });
  });
}
