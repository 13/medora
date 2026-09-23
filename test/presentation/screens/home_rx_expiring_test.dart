/// The Home "prescriptions expiring" card (Task 11): hidden with nothing
/// due, shown for open/partial prescriptions with a known last day within a
/// week, capped to three, soonest first, and tappable to the detail screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

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
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  // A tall viewport, like the other Home card tests: Home overflows the
  // default 600 dp test surface once several cards are populated, and a
  // scrolled-out-of-view row reads as "offstage" to `find`, which would
  // make a real bug (the card missing) indistinguishable from a viewport
  // that is merely too short to show it.
  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> saveRx(
    ProviderContainer container, {
    required String id,
    required String description,
    DateTime? validUntil,
    DateTime? closedOn,
  }) async {
    await container
        .read(rxRepositoryProvider)
        .saveRx(
          Rx(
            id: id,
            kind: RxKind.ssn,
            issuedOn: DateTime(now.year, now.month),
            validUntil: validUntil,
            items: [RxItem(id: '$id-i', description: description)],
            closedOn: closedOn,
          ),
        );
  }

  testWidgets('with no prescriptions the card renders nothing', (tester) async {
    useTallPhone(tester);
    final container = ProviderContainer(overrides: await overrides());
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.rxExpiringTitle), findsNothing);
    expect(find.byIcon(Icons.receipt_long_outlined), findsNothing);
  });

  testWidgets('shows the soonest three open prescriptions due within a week', (
    tester,
  ) async {
    useTallPhone(tester);
    final container = ProviderContainer(overrides: await overrides());
    addTearDown(container.dispose);

    // Within the week, nearest to furthest: Alpha, Bravo, Charlie. Delta
    // is a 4th within the week but loses its slot to the cap. Echo is
    // outside the week. Foxtrot is due tomorrow but already collected.
    await saveRx(
      container,
      id: 'alpha',
      description: 'Alpha',
      validUntil: now.add(const Duration(days: 2)),
    );
    await saveRx(
      container,
      id: 'bravo',
      description: 'Bravo',
      validUntil: now.add(const Duration(days: 4)),
    );
    await saveRx(
      container,
      id: 'charlie',
      description: 'Charlie',
      validUntil: now.add(const Duration(days: 6)),
    );
    await saveRx(
      container,
      id: 'delta',
      description: 'Delta',
      validUntil: now.add(const Duration(days: 7)),
    );
    await saveRx(
      container,
      id: 'echo',
      description: 'Echo',
      validUntil: now.add(const Duration(days: 10)),
    );
    await saveRx(
      container,
      id: 'foxtrot',
      description: 'Foxtrot',
      validUntil: now.add(const Duration(days: 1)),
      closedOn: now,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.rxExpiringTitle), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Bravo'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    expect(
      find.text('Delta'),
      findsNothing,
      reason: 'the 4th nearest, over the 3-row cap',
    );
    expect(find.text('Echo'), findsNothing, reason: 'more than a week out');
    expect(
      find.text('Foxtrot'),
      findsNothing,
      reason: 'already collected, so no longer open',
    );
    expect(find.byIcon(Icons.receipt_long_outlined), findsNWidgets(3));
  });

  testWidgets('a row opens the prescription it names', (tester) async {
    useTallPhone(tester);
    final container = ProviderContainer(overrides: await overrides());
    addTearDown(container.dispose);
    await saveRx(
      container,
      id: 'alpha',
      description: 'Alpha',
      validUntil: now.add(const Duration(days: 2)),
    );

    final router = GoRouter(
      initialLocation: AppRoutes.home,
      routes: [
        GoRoute(path: AppRoutes.home, builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: AppRoutes.rxDetail,
          builder: (_, state) =>
              Text('rx-detail:${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    final previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en';
    addTearDown(() => Intl.defaultLocale = previousLocale);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('rx-detail:alpha'), findsOneWidget);
  });
}
