/// End-to-end smoke tests through the real router: enough of each main flow
/// to notice a screen that no longer works at all. The depth lives in the
/// per-screen tests; these only prove the flows connect.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_scanner_ports.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  // The REAL clock, deliberately. getTodaysDoseLogs and
  // DoseMaintenanceService key off the wall clock by design, not off
  // nowProvider, so a dose seeded relative to the real now has to be judged
  // against the real now too: with a fixed 2026 clock in nowProvider the Now
  // card compares today's dose against a date months in the past and never
  // reaches its overdue state. Nothing here asserts a formatted date, so a
  // fixed clock buys this file nothing.
  final now = DateTime.now();

  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  /// Pumps the real app: the real router, a real database, fake ports.
  ///
  /// [caps] decides whether the scanner exists at all — the scanner route
  /// and Home's scanner button are both gated on `hasCamera`.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    PlatformCapabilities caps = PlatformCapabilities.desktop,
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en';
    addTearDown(() => Intl.defaultLocale = previousLocale);

    // 'onboarding_seen' keeps the first-run sheet out of these flows, and
    // 'biometrics_enabled' keeps the BiometricGate wrapping every shell
    // route (app_router.dart, ShellRoute) from locking the app: the gate
    // keys off this pref, not off PlatformCapabilities.hasBiometrics.
    SharedPreferences.setMockInitialValues({
      'app_mode': 'localOnly',
      'onboarding_seen': true,
      'biometrics_enabled': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(caps),
        nowProvider.overrideWithValue(() => now),
        ...extra,
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('add a medication and see it in the list and on the dashboard', (
    tester,
  ) async {
    await pumpApp(tester);

    // Medications tab → add.
    await tester.tap(find.byIcon(Icons.medication_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(MedicationListScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Medication Name *').first,
      'Moment 200',
    );
    // Quantity defaults to 1; zero makes it low stock, which is what puts
    // it on the dashboard without a date picker.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity *').first,
      '0',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();

    // The Add screen pops itself, so this is the list again.
    expect(find.byType(MedicationListScreen), findsOneWidget);
    expect(find.text('Moment 200'), findsWidgets);

    // And Home shows it under Low Stock.
    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Moment 200'), findsOneWidget);
    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('mark a dose taken from Home and undo it', (tester) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(now, minutes: 10),
    );

    await pumpApp(tester);
    expect(find.text('Tachipirina'), findsOneWidget);
    // Seeded ten minutes ago, so the Now card is in its overdue state.
    expect(find.text('Overdue'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();
    expect(find.text('All doses done for today'), findsOneWidget);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'taken',
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Next dose'), findsOneWidget);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'pending',
    );
  });

  testWidgets('the settings button opens Settings', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('the return-only scanner route builds a return-only scanner', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      caps: PlatformCapabilities.mobile,
      extra: scannerOverrides(camera: FakeCamera(opens: false)),
    );

    // The route AddMedicationScreen pushes for a code it will keep. Nothing
    // outside a hand-rolled test router has ever parsed this query string.
    unawaited(
      container.read(appRouterProvider).push(AppRoutes.scannerReturnOnly),
    );
    await tester.pumpAndSettle();

    final screen = tester.widget<BarcodeScannerScreen>(
      find.byType(BarcodeScannerScreen),
    );
    expect(screen.returnBarcodeOnly, isTrue);

    // And the plain scanner route is not return-only.
    container.read(appRouterProvider).pop();
    await tester.pumpAndSettle();
    unawaited(container.read(appRouterProvider).push(AppRoutes.scanner));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BarcodeScannerScreen>(find.byType(BarcodeScannerScreen))
          .returnBarcodeOnly,
      isFalse,
    );
  });
}
