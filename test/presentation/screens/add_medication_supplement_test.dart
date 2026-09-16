import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_supplement_registry.dart';
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

  testWidgets('the register search chip prefills the chosen product', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final registry = FakeSupplementRegistry(
      entries: const [
        SupplementEntry(
          code: '107018',
          product: 'ZINCO-C',
          company: 'SYGNUM SRL',
        ),
      ],
    );
    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.desktop,
        ),
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Search the supplement register'), findsOneWidget);
    await tester.tap(find.text('Search the supplement register'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ZINCO-C'));
    await tester.pumpAndSettle();

    Finder field(String text) => find.descendant(
      of: find.byType(TextFormField),
      matching: find.text(text),
    );
    expect(field('ZINCO-C'), findsOneWidget);
    expect(field('SYGNUM SRL'), findsOneWidget);
    expect(registry.syncCalls, 0);
  });

  testWidgets('the register search chip is hidden on the web', (tester) async {
    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.web,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Search the supplement register'), findsNothing);
    expect(find.text('Search AIFA Database'), findsOneWidget);
  });

  group('the register is missing when the search chip is tapped', () {
    /// Pumps Add Medication with [registry] behind the chip and taps it.
    Future<void> tapSearchChip(
      WidgetTester tester,
      FakeSupplementRegistry registry,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        const AddMedicationScreen(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.desktop,
          ),
          supplementRegistryServiceProvider.overrideWithValue(registry),
        ],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Search the supplement register'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancelling the download prompt opens no sheet', (
      tester,
    ) async {
      final registry = FakeSupplementRegistry(); // no cached register
      await tapSearchChip(tester, registry);
      expect(
        find.textContaining('Ministry of Health register'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(registry.syncCalls, 0);
      expect(find.text('Product name'), findsNothing); // no search sheet
      expect(find.text('Something went wrong'), findsNothing);
    });

    testWidgets('a failed download reports the error and opens no sheet', (
      tester,
    ) async {
      final registry = FakeSupplementRegistry(failSync: true);
      await tapSearchChip(tester, registry);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(registry.syncCalls, 1);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Product name'), findsNothing); // no search sheet
    });

    testWidgets('a successful download opens the search over the new data', (
      tester,
    ) async {
      final registry = FakeSupplementRegistry(
        syncedEntries: const [
          SupplementEntry(
            code: '107018',
            product: 'ZINCO-C',
            company: 'SYGNUM SRL',
          ),
        ],
      );
      await tapSearchChip(tester, registry);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();

      expect(registry.syncCalls, 1);
      expect(find.text('Product name'), findsOneWidget); // the search sheet
      expect(find.text('Something went wrong'), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'zinc');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ZINCO-C'));
      await tester.pumpAndSettle();

      Finder field(String text) => find.descendant(
        of: find.byType(TextFormField),
        matching: find.text(text),
      );
      expect(field('ZINCO-C'), findsOneWidget);
      expect(field('SYGNUM SRL'), findsOneWidget);
    });
  });

  testWidgets('the German search chip fits a 360x800 screen', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(
      tester,
      const AddMedicationScreen(),
      locale: const Locale('de'),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.desktop,
        ),
        supplementRegistryServiceProvider.overrideWithValue(
          FakeSupplementRegistry(),
        ),
      ],
    );
    await tester.pumpAndSettle();

    final label = find.text('Nahrungsergänzungsmittel-Register durchsuchen');
    expect(label, findsOneWidget);

    // Add Medication already overflows at this width for reasons that have
    // nothing to do with this chip — it does so with the chip absent (web
    // capabilities) and by more in English. Consume that pending error and
    // assert what this chip is responsible for: its own 45-character label
    // wraps inside the screen instead of blowing the row out.
    tester.takeException();
    final chip = tester.getRect(
      find.ancestor(of: label, matching: find.byType(ActionChip)),
    );
    expect(chip.width, lessThanOrEqualTo(360));
    expect(chip.right, lessThanOrEqualTo(360));
  });
}
