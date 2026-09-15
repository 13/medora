import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

const _fixedBuildInfo = BuildInfo(
  version: '1.0.0',
  buildNumber: '11',
  buildDate: '2026-09-15T20:14:00Z',
  gitSha: 'abc1234',
  channel: 'ci',
  dartVersion: '3.12.2',
);

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> baseOverrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    buildInfoProvider.overrideWith((ref) async => _fixedBuildInfo),
  ];

  testWidgets(
    'local-only desktop shows the grouped sections without Security or Advanced',
    (tester) async {
      await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        overrides: await baseOverrides(),
      );
      await tester.pumpAndSettle();

      for (final title in [
        'Appearance',
        'Notifications',
        'Data',
        'Cloud sync',
        'Danger Zone',
        'About',
      ]) {
        await tester.scrollUntilVisible(
          find.text(title),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Security'), findsNothing);
      expect(find.text('Advanced'), findsNothing);
    },
  );

  testWidgets('About shows version, build, date, commit and channel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await baseOverrides(),
    );
    await tester.pumpAndSettle();

    final expectedDate =
        '${DateTime.parse(_fixedBuildInfo.buildDate).toUtc().dateTimeFormatted} UTC';

    for (final text in [
      '1.0.0',
      '11',
      expectedDate,
      'abc1234',
      'CI',
      '3.12.2',
    ]) {
      await tester.scrollUntilVisible(
        find.text(text),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });

  testWidgets(
    'long-pressing an About row copies a summary and shows a confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        overrides: await baseOverrides(),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('1.0.0'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.longPress(find.text('1.0.0'));
      await tester.pumpAndSettle();

      expect(find.text('Copied'), findsOneWidget);
    },
  );

  testWidgets(
    'AIFA database tile keeps its title on one line at 360px width in de',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        overrides: await baseOverrides(),
        locale: const Locale('de'),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('AIFA-Datenbank'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('AIFA-Datenbank'), findsOneWidget);
    },
  );

  testWidgets('the Data group offers a backup and a restore tile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await baseOverrides(),
    );
    await tester.pumpAndSettle();

    for (final title in ['Back up data', 'Restore from backup']) {
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });
}
