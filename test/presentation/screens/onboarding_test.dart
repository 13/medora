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
}
