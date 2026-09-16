import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

/// Turning cloud mode on can fail (no preferences backend, a pref write that
/// throws); the screen has to say so rather than look like it worked.
class _RefusingAppMode extends AppModeNotifier {
  @override
  Future<void> set(AppMode mode) async => throw StateError('prefs are gone');
}

/// Only the capability under test, so pumping Settings does not also build
/// the supplement register or biometrics tiles.
const _notificationsOnly = PlatformCapabilities(
  hasCamera: false,
  hasLocalNotifications: true,
  hasFileShare: false,
  hasBiometrics: false,
  hasInAppUpdates: false,
  hasSupplementRegister: false,
);

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
      // The German title is the longest of the three; on the narrowest phone
      // it must still fit the tile on a single line rather than wrap or
      // ellipsize behind the trailing control.
      final title = tester.renderObject<RenderParagraph>(
        find.text('AIFA-Datenbank'),
      );
      expect(
        title.textSize.height,
        lessThanOrEqualTo(title.preferredLineHeight * 1.5),
        reason: 'the AIFA tile title wrapped onto a second line at 360px',
      );
      expect(title.didExceedMaxLines, isFalse);
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

  testWidgets('an unconfigured build offers to configure cloud from Settings', (
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

    await tester.scrollUntilVisible(
      find.text('Not configured — tap Configure'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Not configured — tap Configure'), findsOneWidget);
    // One entry point while there is nothing configured: the status tile's
    // own button, not a second tile saying the same thing.
    expect(find.text('Cloud configuration'), findsNothing);

    await tester.tap(find.text('Configure').last);
    await tester.pumpAndSettle();

    expect(find.text('Project URL'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
  });

  testWidgets('credentials saved on this device are named in the cloud group', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      CloudCredentials.prefsUrlKey: 'https://abcdefgh.supabase.co',
      CloudCredentials.prefsKeyKey: 'anon-key',
    });

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: await baseOverrides(),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Configured on this device'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Configured on this device'), findsOneWidget);
    expect(find.text('anon-key'), findsNothing);

    // With a configuration in place the tile is how it is edited or cleared.
    await tester.scrollUntilVisible(
      find.text('Cloud configuration'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Cloud configuration'));
    await tester.pumpAndSettle();
    expect(find.text('Project URL'), findsOneWidget);
  });

  testWidgets(
    'a "Turn on" that cannot be saved reports it and keeps the mode',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Configured, so the tile offers "Turn on" - no client is created, and
      // nothing here reaches Supabase.
      SupabaseConfig.debugSetConfiguredForTest(true);
      addTearDown(SupabaseConfig.resetForTest);

      final container = await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        overrides: [
          ...await baseOverrides(),
          appModeProvider.overrideWith(_RefusingAppMode.new),
        ],
      );
      await tester.pumpAndSettle();

      final turnOn = find.text('Turn on');
      await tester.scrollUntilVisible(
        turnOn,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(turnOn);
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('prefs are gone'), findsOneWidget);
      expect(container.read(appModeProvider), AppMode.localOnly);
    },
  );

  testWidgets('stock and expiry reminders are on by default and can be '
      'turned off', (tester) async {
    final container = await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(_notificationsOnly),
        buildInfoProvider.overrideWith((ref) async => _fixedBuildInfo),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Stock and expiry reminders'), findsOneWidget);
    expect(
      container.read(stockRemindersEnabledProvider),
      isTrue,
      reason: 'the user asked for these reminders, so they default to on',
    );

    await tester.tap(find.text('Stock and expiry reminders'));
    await tester.pumpAndSettle();

    expect(container.read(stockRemindersEnabledProvider), isFalse);
  });
}
