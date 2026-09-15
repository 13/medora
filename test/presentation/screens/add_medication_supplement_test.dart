import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/services/supplement_registry_service.dart';
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

  testWidgets('a supplement register entry prefills Add Medication', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(
        initialBarcode: '107018',
        lookupResult: SupplementEntry(
          code: '107018',
          product: 'ZINCO-C',
          company: 'SYGNUM SRL',
        ),
      ),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.desktop,
        ),
      ],
    );
    await tester.pumpAndSettle();

    Finder field(String text) => find.descendant(
      of: find.byType(TextFormField),
      matching: find.text(text),
    );
    expect(field('ZINCO-C'), findsOneWidget);
    expect(field('SYGNUM SRL'), findsOneWidget);
    expect(field('107018'), findsOneWidget);
    expect(find.text('Supplement'), findsOneWidget); // category
  });
}
