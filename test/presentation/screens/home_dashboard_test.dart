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

/// How long the deliberately slow cabinet takes to answer a re-read.
const _slowRead = Duration(seconds: 3);

/// The one medication every fake cabinet below serves once it works.
const _alpha = Medication(id: 'a', name: 'Alpha', quantity: 0);

/// A cabinet that fails its first read and serves one low-stock medication
/// afterwards — the shape of a transient database error behind Retry.
///
/// Riverpod builds a fresh notifier for every rebuild, so the build count
/// cannot live on the instance; each test passes in its own counter rather
/// than sharing a file-level one, which would make the cases depend on the
/// order they run in.
class _FailsOnceMedications extends MedicationListNotifier {
  _FailsOnceMedications(this.countBuild);

  /// Returns this build's 1-based number.
  final int Function() countBuild;

  @override
  Future<List<Medication>> build() async {
    if (countBuild() == 1) throw Exception('db down');
    return const [_alpha];
  }
}

/// A cabinet that never works, the way a locked or corrupt database read
/// keeps failing however often it is retried.
class _AlwaysFailsMedications extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async => throw Exception('db down');
}

/// A cabinet whose first read is instant and whose every later read takes
/// [_slowRead] — a cold re-read behind a pull to refresh.
class _SlowSecondRead extends MedicationListNotifier {
  _SlowSecondRead(this.countBuild);

  /// Returns this build's 1-based number.
  final int Function() countBuild;

  @override
  Future<List<Medication>> build() async {
    if (countBuild() > 1) await Future<void>.delayed(_slowRead);
    return const [_alpha];
  }
}

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

  /// Pumps [total] of fake time in frame-sized steps.
  ///
  /// `pumpAndSettle` is no use where a spinner turns or a retry timer is
  /// pending — it either never settles or returns before the timer is due —
  /// and one long `pump` collapses every intermediate frame into one, so a
  /// widget that appeared and vanished again leaves no trace.
  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 50);
    for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
      await tester.pump(step);
    }
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
    // the only place the other two are represented at all. This is a record
    // of today's behaviour, not a requirement: _ExpiringSoonCard already
    // has a `moreCount` row, and a task that gives Low Stock and Active
    // Treatments the same affordance should change this expectation rather
    // than work around it.
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
    var builds = 0;
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(
          () => _FailsOnceMedications(() => ++builds),
        ),
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

  testWidgets('the refresh spinner stays up until the slow read lands', (
    tester,
  ) async {
    useTallPhone(tester);
    var builds = 0;
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(
          () => _SlowSecondRead(() => ++builds),
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);

    // Not pullToRefresh: the indicator turns for as long as the read is in
    // flight, so pumpAndSettle would run out of patience rather than
    // return. Every pump below is deliberate.
    await tester.fling(find.byType(ListView), const Offset(0, 800), 1000);
    await pumpFor(tester, const Duration(milliseconds: 600));
    expect(builds, 2, reason: 'the pull re-read the cabinet');

    // A second and a half in, with that read still pending, the indicator
    // is still on screen. Drop the `await` from onRefresh and it has long
    // since retracted by here, telling the user that a dashboard still
    // showing yesterday's data is fresh.
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    // Only once the source lands does the pull actually finish.
    await tester.pump(_slowRead);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('a failed read reaches the error shell within a second', (
    tester,
  ) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(_AlwaysFailsMedications.new),
      ],
      // Deliberately no `retry:` override: this case is about the policy the
      // app itself ships (`medoraRetry`, the same one main.dart hands its
      // ProviderScope). A provider that is waiting out a retry stays
      // AsyncLoading, so under Riverpod's own default — ten attempts, 200 ms
      // doubling to 6.4 s — these cards show skeletons for some thirteen
      // seconds before the user is told anything is wrong, and this fails.
    );
    await tester.pump();
    await pumpFor(tester, const Duration(seconds: 1));

    expect(find.text('Something went wrong'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Retry'), findsNWidgets(2));
  });

  testWidgets('a transient failure heals itself without a tap', (tester) async {
    useTallPhone(tester);
    var builds = 0;
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(
          () => _FailsOnceMedications(() => ++builds),
        ),
      ],
    );
    await tester.pump();
    await pumpFor(tester, const Duration(seconds: 1));

    // Nothing was tapped: the one retry the policy allows is what recovered
    // the cabinet, which is the half of the bargain that pays for the short
    // budget above.
    expect(builds, 2, reason: 'exactly one automatic retry');
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });
}
