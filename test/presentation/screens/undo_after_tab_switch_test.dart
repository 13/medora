import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Regression test for the Undo SnackBar action.
///
/// [MainShellScreen] index-selects its body, so switching tabs disposes the
/// screen that showed the SnackBar while the SnackBar itself survives (the
/// ScaffoldMessenger re-hosts it on the new tab's Scaffold). Reading a
/// provider off the disposed widget's `ref` at tap time throws a StateError
/// under Riverpod 3 and Undo silently does nothing — the action object has
/// to be captured before the SnackBar is shown.
void main() {
  final now = DateTime.now();
  // This test pumps MainShellScreen, which runs AppStartupTasks (and
  // DoseMaintenanceService) on init — those key off the real wall clock by
  // design, not nowProvider, so a seed more than the missed-dose grace
  // window (2h by default) stale gets swept to "missed" before the test
  // can tap Take. `recentToday` seeds relative to the REAL now, clamped to
  // stay on today's calendar day and well inside the grace window,
  // whatever the wall-clock hour the suite runs at.

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({'onboarding_seen': true});
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

  testWidgets('Undo still works after the SnackBar outlives its tab', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(now, minutes: 10),
    );

    await pumpMedoraApp(
      tester,
      const MainShellScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // Take the dose from the Home "Now" card.
    expect(find.text('Tachipirina'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'taken',
    );

    // Switch tabs: HomeScreen (and its ref) is disposed, the SnackBar is not.
    await tester.tap(find.byIcon(Icons.medication_outlined));
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'pending',
    );
  });
}
