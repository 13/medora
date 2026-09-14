import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
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
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.desktop),
      ];

  testWidgets('shows three sections and saves a medication with just a name', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await pumpMedoraApp(tester, const AddMedicationScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    expect(find.byType(FormSection), findsNWidgets(3));
    expect(find.text('Basics'), findsOneWidget);
    expect(find.text('Stock & storage'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Medication Name *').first, 'Moment');
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();

    final list = await c.read(medicationListProvider.future);
    expect(list.map((m) => m.name), ['Moment']);
  });

  testWidgets('empty name shows the validator and keeps Basics expanded', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMedoraApp(tester, const AddMedicationScreen(), overrides: await overrides());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a medication name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Medication Name *'), findsOneWidget); // still visible ⇒ section expanded
  });

  testWidgets('collapsing Basics does not bypass validation and the section reopens on error', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await pumpMedoraApp(tester, const AddMedicationScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Basics'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter a medication name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Medication Name *'), findsOneWidget);

    final list = await c.read(medicationListProvider.future);
    expect(list, isEmpty);
  });

  testWidgets('collapsed Stock section shows a summary', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMedoraApp(tester, const AddMedicationScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    expect(find.textContaining('min 0'), findsOneWidget);

    await tester.tap(find.text('Stock & storage'));
    await tester.pumpAndSettle();

    expect(find.textContaining('min 0'), findsNothing);
  });
}
