import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/onboarding_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/screens/onboarding/onboarding_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  /// Overrides sharing the currently cached [SharedPreferences] instance, so
  /// a second pump sees what the first pump wrote.
  Future<List<Override>> overrides() async => [
        sharedPreferencesProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider
            .overrideWithValue(PlatformCapabilities.desktop),
      ];

  testWidgets('first launch shows the onboarding and marks it seen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final container =
        await pumpMedoraApp(tester, const MainShellScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    // Page 1
    expect(find.byType(OnboardingSheet), findsOneWidget);
    expect(find.text('Your cabinet'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    // Page 2
    expect(
      find.text('Group medicines into a treatment with a schedule for who '
          'takes what and when.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    // Page 3 — last page: Done, no Skip.
    expect(find.text('Daily doses'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Skip'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingSheet), findsNothing);
    expect(prefs.getBool('onboarding_seen'), isTrue);
    expect(container.read(onboardingSeenProvider), isTrue);
  });

  testWidgets('onboarding does not come back on the next launch', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await pumpMedoraApp(tester, const MainShellScreen(), overrides: await overrides());
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingSheet), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingSheet), findsNothing);

    // Second launch, same persisted preferences.
    await pumpMedoraApp(tester, const MainShellScreen(), overrides: await overrides());
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingSheet), findsNothing);
  });

  testWidgets('swiping the sheet away also marks onboarding seen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await pumpMedoraApp(tester, const MainShellScreen(), overrides: await overrides());
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingSheet), findsOneWidget);

    await tester.drag(find.byType(OnboardingSheet), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingSheet), findsNothing);
    expect(prefs.getBool('onboarding_seen'), isTrue);
  });

  testWidgets('onboarding is skipped when it has already been seen', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_seen': true});

    await pumpMedoraApp(tester, const MainShellScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingSheet), findsNothing);
  });

  testWidgets('onboarding sheet does not overflow at a short landscape viewport', (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpOpenSheet(tester);

    expect(find.byType(OnboardingSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding sheet does not overflow at 2x text scale and stays usable', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pumpOpenSheet(tester);

    // Page 1
    expect(find.byType(OnboardingSheet), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Page 2
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Page 3 — last page: Done.
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(OnboardingSheet), findsNothing);
  });
}

/// Pumps just the onboarding sheet (not the whole [MainShellScreen]/app), so
/// these overflow regression tests stay scoped to the sheet itself rather
/// than incidentally exercising unrelated screens underneath.
Future<void> _pumpOpenSheet(WidgetTester tester) async {
  await pumpMedoraApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showOnboardingSheet(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}
