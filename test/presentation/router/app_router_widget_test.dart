import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  Future<ProviderContainer> pumpApp(WidgetTester tester, {required String mode}) async {
    SharedPreferences.setMockInitialValues({'app_mode': mode});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('local-only mode never shows the auth screen', (tester) async {
    final container = await pumpApp(tester, mode: 'localOnly');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AuthScreen), findsNothing);
    expect(container.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path, '/');

    // MainShellScreen schedules a delayed sync call in initState; flush it so
    // no pending Timer trips the framework's teardown invariant check. This
    // is unrelated to routing/auth.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('cloud mode without a session redirects to /auth, and choosing local-only returns home',
      (tester) async {
    final container = await pumpApp(tester, mode: 'cloud');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(container.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path, '/auth');

    await container.read(appModeProvider.notifier).set(AppMode.localOnly);
    await tester.pump();
    // The /auth -> / transition is an animated MaterialPage push; AuthScreen
    // stays mounted mid-transition, so settle the animation before asserting
    // it is gone (a fixed short pump is not reliably enough).
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsNothing);
    expect(container.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path, '/');

    // MainShellScreen schedules a delayed sync call in initState; flush it so
    // no pending Timer trips the framework's teardown invariant check. This
    // is unrelated to routing/auth.
    await tester.pump(const Duration(seconds: 3));
  });
}
