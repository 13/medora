import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_supplement_registry.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides(
    FakeSupplementRegistry registry, {
    PlatformCapabilities caps = PlatformCapabilities.desktop,
  }) async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(caps),
    supplementRegistryServiceProvider.overrideWithValue(registry),
  ];

  /// A surface tall enough that the whole settings list is laid out.
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('shows the count and the register date in German', (
    tester,
  ) async {
    tallSurface(tester);
    final registry = FakeSupplementRegistry(
      entries: const [_zinco],
      lastSyncAt: DateTime(2026, 9, 15),
      sourceUpdatedAt: DateTime.parse('2026-09-01'),
    );
    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await overrides(registry),
      locale: const Locale('de'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nahrungsergänzungsmittel-Register'), findsOneWidget);
    expect(
      find.text('Stand: ${DateTime.parse('2026-09-01').formatted}'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Letzte Aktualisierung: ${DateTime(2026, 9, 15).formatted} · 1',
      ),
      findsOneWidget,
    );
    expect(find.text('Register aktualisieren'), findsOneWidget);
  });

  testWidgets('downloads the register from the tile', (tester) async {
    tallSurface(tester);
    final registry = FakeSupplementRegistry(syncedEntries: const [_zinco]);
    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await overrides(registry),
    );
    await tester.pumpAndSettle();

    expect(find.text('Food supplement register'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Download'));
    await tester.pumpAndSettle();

    expect(registry.syncCalls, 1);
    expect(find.text('Register updated (1 products)'), findsOneWidget);
    expect(find.text('Register as of Sep 1, 2026'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Update register'), findsOneWidget);
  });

  testWidgets('a failed download shows the error', (tester) async {
    tallSurface(tester);
    final registry = FakeSupplementRegistry(failSync: true);
    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await overrides(registry),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Download'));
    await tester.pumpAndSettle();

    expect(registry.syncCalls, 1);
    expect(find.text('Failed to download database'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Download'), findsOneWidget);
  });

  testWidgets('is hidden without the capability (web)', (tester) async {
    tallSurface(tester);
    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await overrides(
        FakeSupplementRegistry(),
        caps: PlatformCapabilities.web,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Food supplement register'), findsNothing);
  });
}
