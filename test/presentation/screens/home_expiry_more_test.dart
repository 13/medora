/// The expiry card shows at most three rows. Expired medications now win
/// those slots, so the merely-expiring ones they push off have to be
/// reachable - and countable - rather than silently absent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show Override, UncontrolledProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:medora/presentation/screens/medication/expiring_medications_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
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

  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Three expired and two expiring: the case where the card's three slots
  /// are taken entirely by one of the two populations.
  Future<void> seedFiveExpiryRows() async {
    final db = await AppDatabase.instance.database;
    const rows = [
      ('e1', 'Aulin', '2025-10-01'),
      ('e2', 'Bentelan', '2025-11-01'),
      ('e3', 'Clenil', '2025-12-01'),
      ('s1', 'Moment 200', '2026-03-10'),
      ('s2', 'Tachipirina', '2026-03-20'),
    ];
    for (final (id, name, expiry) in rows) {
      await db.insert('medications', {
        'id': id,
        'name': name,
        'quantity': 5,
        'expiry_date': expiry,
      });
    }
  }

  testWidgets('the card counts the rows it had to leave out', (tester) async {
    useTallPhone(tester);
    await seedFiveExpiryRows();

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // The three most urgent rows, all expired.
    expect(find.text('Aulin'), findsOneWidget);
    expect(find.text('Bentelan'), findsOneWidget);
    expect(find.text('Clenil'), findsOneWidget);
    // The two they pushed off are not on the card...
    expect(find.text('Moment 200'), findsNothing);
    expect(find.text('Tachipirina'), findsNothing);
    // ...but the card says so instead of looking complete.
    expect(find.text('2 more'), findsOneWidget);
  });

  testWidgets('a card that shows everything says nothing extra', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'e1',
      'name': 'Aulin',
      'quantity': 5,
      'expiry_date': '2025-10-01',
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('more'), findsNothing);
  });

  /// Home under a real router, so "See All" and the "+N more" row can be
  /// followed to whatever they actually open.
  Future<void> pumpWithRouter(WidgetTester tester) async {
    final container = ProviderContainer(overrides: await overrides());
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: AppRoutes.home,
      routes: [
        GoRoute(path: AppRoutes.home, builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: AppRoutes.expiringMedications,
          builder: (_, _) => const ExpiringMedicationsScreen(),
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
  }

  testWidgets('"See All" and the counted row open the same list, in the same '
      'order', (tester) async {
    useTallPhone(tester);
    await seedFiveExpiryRows();
    await pumpWithRouter(tester);

    // The card's own order: most urgent first, name as the tiebreak.
    const inOrder = [
      'Aulin',
      'Bentelan',
      'Clenil',
      'Moment 200',
      'Tachipirina',
    ];
    void expectTheWholeListInTheCardsOrder() {
      final tops = <double>[];
      for (final name in inOrder) {
        expect(find.text(name), findsOneWidget, reason: '$name is missing');
        tops.add(tester.getTopLeft(find.text(name)).dy);
      }
      expect(
        tops,
        [...tops]..sort(),
        reason: 'the destination must not re-sort the card alphabetically',
      );
    }

    final header = find
        .ancestor(
          of: find.text('Expired & Expiring'),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(
      find.descendant(of: header, matching: find.text('See All')),
    );
    await tester.pumpAndSettle();
    expectTheWholeListInTheCardsOrder();

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('2 more'));
    await tester.pumpAndSettle();
    expectTheWholeListInTheCardsOrder();
  });
}
