/// The settings gear through the real router: on the four main tabs, last
/// in their app bar, and nowhere else.
///
/// This file runs in the default test font on purpose: its glyphs are about
/// three times as wide as Inter's, so the 1.6x overflow checks are a strict
/// stand-in for a larger scale on a device (with Inter, the two overflows
/// they caught appear only from about 2.4x on a 320 dp phone). Text measured
/// in real fonts lives in settings_gear_layout_test.dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/widgets/settings_action.dart';

import '../../helpers/pump_shell.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  /// Every tappable button in the visible app bar.
  List<Rect> actionRects(WidgetTester tester) {
    final bar = find.byType(AppBar).last;
    return [
      for (final type in [IconButton, ActionChip])
        for (final e
            in find.descendant(of: bar, matching: find.byType(type)).evaluate())
          tester.getRect(find.byElementPredicate((x) => x == e)),
    ];
  }

  for (final (index, tab) in mainTabs.indexed) {
    testWidgets('$tab: the gear is last and opens Settings; back returns to '
        '$tab', (tester) async {
      await pumpShell(tester);
      await openTab(tester, index);

      final gear = find.byKey(SettingsAction.buttonKey);
      expect(gear, findsOneWidget);
      final gearRect = tester.getRect(gear);
      for (final other in actionRects(tester)) {
        if (other == gearRect) continue;
        expect(
          other.right,
          lessThanOrEqualTo(gearRect.left + 0.5),
          reason: 'an action sits right of the gear on $tab',
        );
      }

      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byKey(SettingsAction.buttonKey), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, index);
    });
  }

  // A reminder tap calls router.go('/doses'). go() drops a pushed Settings
  // without completing its push future, so a guard reset only on that future
  // left the gear dead until the next tab switch.
  for (final location in const [AppRoutes.doses, AppRoutes.home]) {
    testWidgets('the gear works again after go($location) closed Settings', (
      tester,
    ) async {
      final container = await pumpShell(tester);
      final router = container.read(appRouterProvider);
      router.go(location);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SettingsAction.buttonKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      router.go(location);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);

      await tester.tap(find.byKey(SettingsAction.buttonKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      // And the guard still holds against a double tap afterwards.
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsAction.buttonKey));
      await tester.tap(
        find.byKey(SettingsAction.buttonKey),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
    });
  }

  // Search is a short-lived mode whose only exit is the close button; the
  // gear took 48 dp from the field and cut the German hints from 1.1x.
  for (final (index, tab) in const [(1, 'Medications'), (2, 'Treatments')]) {
    testWidgets('$tab: searching hides the gear and closing brings it back', (
      tester,
    ) async {
      await pumpShell(tester);
      await openTab(tester, index);
      final bar = find.byType(AppBar).last;

      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: bar, matching: find.byType(TextField)),
        findsOneWidget,
      );
      expect(find.byKey(SettingsAction.buttonKey), findsNothing);
      // Only the search's own action is left, and it is labelled.
      expect(
        find.descendant(of: bar, matching: find.byType(IconButton)),
        findsOneWidget,
      );
      expect(find.byTooltip('Close'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: bar, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(find.byKey(SettingsAction.buttonKey), findsOneWidget);
      expect(find.byTooltip('Search'), findsOneWidget);
    });
  }

  // Desktop covers the scanner's "unavailable" screen as well.
  for (final (name, caps) in const [
    ('mobile', PlatformCapabilities.mobile),
    ('desktop', PlatformCapabilities.desktop),
  ]) {
    testWidgets('no gear on forms, detail screens and the scanner ($name)', (
      tester,
    ) async {
      final container = await pumpShell(tester, caps: caps);
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final router = container.read(appRouterProvider);
      for (final route in [
        AppRoutes.addMedication,
        '/medications/${seeded.medicationId}',
        '/medications/${seeded.medicationId}/edit',
        AppRoutes.expiringMedications,
        AppRoutes.addTreatment,
        '/treatments/${seeded.treatmentId}',
        '/treatments/${seeded.treatmentId}/edit',
        AppRoutes.doseHistory,
        AppRoutes.scanner,
        AppRoutes.settings,
        AppRoutes.family,
        AppRoutes.export,
      ]) {
        unawaited(router.push(route));
        await tester.pumpAndSettle();
        expect(
          find.byKey(SettingsAction.buttonKey),
          findsNothing,
          reason: 'a gear on $route ($name)',
        );
        router.pop();
        await tester.pumpAndSettle();
      }
    });
  }

  for (final locale in const ['de', 'it', 'en']) {
    for (final (index, tab) in mainTabs.indexed) {
      testWidgets('$tab at 360 dp, $locale, 1.6x text: nothing overflows and '
          'the gear is fully on screen', (tester) async {
        await pumpShell(
          tester,
          size: const Size(360, 800),
          locale: Locale(locale),
          textScale: 1.6,
        );
        await openTab(tester, index);
        expect(tester.takeException(), isNull);
        final gear = tester.getRect(find.byKey(SettingsAction.buttonKey));
        expect(gear.left, greaterThanOrEqualTo(0));
        expect(gear.right, lessThanOrEqualTo(360));
        expect(gear.width, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(SettingsAction.buttonKey));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
      });
    }
  }

  for (final (index, tab) in mainTabs.indexed) {
    testWidgets('$tab at 360 dp, German, 2.0x text: the app bar keeps the '
        'gear on screen and tappable', (tester) async {
      // Some page bodies overflow at 2.0x already (outside this change, see
      // the design's deferred list); only the app bar is checked here.
      final errors = await collectFlutterErrors(() async {
        await pumpShell(
          tester,
          size: const Size(360, 800),
          locale: const Locale('de'),
          textScale: 2,
        );
        await openTab(tester, index);
        final gear = tester.getRect(find.byKey(SettingsAction.buttonKey));
        expect(gear.left, greaterThanOrEqualTo(0));
        expect(gear.right, lessThanOrEqualTo(360));
        await tester.tap(find.byKey(SettingsAction.buttonKey));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
      });
      expect(
        errors.where(
          (text) =>
              text.contains('AppBar') || text.contains('NavigationToolbar'),
        ),
        isEmpty,
      );
    });
  }
}
