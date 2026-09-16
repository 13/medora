/// Dashboard states other than the Now card: the Low Stock and Active
/// Treatments cards, the progress bar, the silent three-item truncation,
/// the error/retry path and pull-to-refresh.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// How many times the overridden cabinet has been built this test.
int _medBuilds = 0;

/// A cabinet that fails its first read and serves one low-stock medication
/// afterwards — the shape of a transient database error behind Retry.
class _FailsOnceMedications extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async {
    _medBuilds++;
    if (_medBuilds == 1) throw Exception('db down');
    return const [Medication(id: 'a', name: 'Alpha', quantity: 0)];
  }
}

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUp(() async {
    _medBuilds = 0;
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

  /// Home is a long ListView; a tall viewport puts every section on screen
  /// so the assertions do not have to scroll.
  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Pulls the dashboard down far enough to actually arm the
  /// [RefreshIndicator]. Its trigger threshold is a quarter of the viewport
  /// height (`_kDragContainerExtentPercentage`), so on the tall test phone a
  /// 400 dp pull shows the spinner, snaps back and calls nothing — a test
  /// that pulls too gently passes or fails for reasons of its own.
  Future<void> pullToRefresh(WidgetTester tester) async {
    await tester.fling(find.byType(ListView), const Offset(0, 800), 1000);
    await tester.pumpAndSettle();
  }

  testWidgets('the Low Stock card lists its rows and the tile counts them', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'a',
      'name': 'Alpha',
      'quantity': 0,
      'minimum_stock_level': 0,
    });
    await db.insert('medications', {
      'id': 'b',
      'name': 'Beta',
      'quantity': 2,
      'minimum_stock_level': 5,
    });
    await db.insert('medications', {
      'id': 'c',
      'name': 'Gamma',
      'quantity': 9,
      'minimum_stock_level': 1,
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsNothing);
    expect(find.text('All medications are well stocked'), findsNothing);

    // The row says how much is left, in the card's own words.
    expect(find.text('Left'), findsNWidgets(2));

    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);
  });

  testWidgets('an empty cabinet says both cards are fine', (tester) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('All medications are well stocked'), findsOneWidget);
    expect(find.text('All medications are within date'), findsOneWidget);
    expect(find.text('No active treatments'), findsOneWidget);
    expect(find.text('No doses scheduled for today'), findsOneWidget);
  });

  testWidgets('the Active Treatments card lists the active treatment', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // seedPrescription inserts an active treatment named 'Flu'.
    expect(find.text('Flu'), findsOneWidget);
    expect(find.text('No active treatments'), findsNothing);
    final tile = find
        .ancestor(of: find.text('Treatments'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('an ended treatment leaves the card empty', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);
    await db.update('treatments', {'is_active': 0});

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Flu'), findsNothing);
    expect(find.text('No active treatments'), findsOneWidget);
    final tile = find
        .ancestor(of: find.text('Treatments'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('0')), findsOneWidget);
  });

  testWidgets("the progress bar counts today's doses", (tester) async {
    useTallPhone(tester);
    // getTodaysDoseLogs keys off the real wall clock by design, not
    // nowProvider, so these seeds are placed relative to the real now.
    final real = DateTime.now();
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, recentToday(real), status: 'taken');
    await seedDoseLog(db, s.prescriptionId, laterToday(real));
    await seedDoseLog(db, s.prescriptionId, laterToday(real, minutes: 120));

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 of 3 taken · 2 pending'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(1 / 3, 1e-9));
  });

  testWidgets('with no doses today there is no progress bar at all', (
    tester,
  ) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a fourth low-stock medication is silently dropped', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    for (var i = 1; i <= 5; i++) {
      await db.insert('medications', {
        'id': 'ls$i',
        'name': 'LS$i',
        'quantity': 0,
        'minimum_stock_level': 0,
      });
    }

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // The card takes three and offers no "+N more" affordance; the tile is
    // the only place the other two are represented at all.
    final shown = [
      'LS1',
      'LS2',
      'LS3',
      'LS4',
      'LS5',
    ].where((n) => find.text(n).evaluate().isNotEmpty).length;
    expect(shown, 3, reason: 'the card shows exactly three of the five');

    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('5')), findsOneWidget);
  });

  testWidgets('a failed cabinet read offers a Retry that actually recovers', (
    tester,
  ) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(_FailsOnceMedications.new),
      ],
      // Riverpod retries a failed provider on a timer of its own. Left on,
      // the cabinet heals itself while the test waits and the button is
      // never what recovered it — the assertion below would pass over a
      // Retry that does nothing at all.
      retry: (_, _) => null,
    );
    await tester.pumpAndSettle();

    // Both medication cards render the error shell.
    expect(find.text('Something went wrong'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Retry'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(FilledButton, 'Retry').first);
    await tester.pumpAndSettle();

    // Retry must re-read the cabinet, not just the derived list: otherwise
    // it re-awaits the same failure and nothing ever recovers.
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('pull to refresh re-reads the cabinet', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'a',
      'name': 'Alpha',
      'quantity': 0,
      'minimum_stock_level': 0,
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    // Written underneath the notifier, the way a sync pull writes a row.
    await db.insert('medications', {
      'id': 'b',
      'name': 'Beta',
      'quantity': 0,
      'minimum_stock_level': 0,
    });

    await pullToRefresh(tester);

    expect(find.text('Beta'), findsOneWidget);
    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);
  });

  testWidgets('pull to refresh re-reads the treatments too', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    expect(find.text('No active treatments'), findsOneWidget);

    await seedPrescription(db);

    await pullToRefresh(tester);

    expect(find.text('Flu'), findsOneWidget);
    expect(find.text('No active treatments'), findsNothing);
  });
}
