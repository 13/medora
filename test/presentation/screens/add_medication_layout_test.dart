/// Add Medication has to lay out on a 360 px phone in every language: the
/// quantity unit dropdown sits in a narrow Expanded next to the quantity
/// field, and its longest label ("Suppositories", "Zäpfchen") used to push
/// the row past the viewport.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
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
    platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.mobile),
  ];

  for (final locale in const [Locale('en'), Locale('de'), Locale('it')]) {
    testWidgets('lays out at 360x800 in ${locale.languageCode}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        const AddMedicationScreen(),
        overrides: await overrides(),
        locale: locale,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
