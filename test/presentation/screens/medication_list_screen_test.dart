import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
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
  ];

  testWidgets('swipe → Archive shows an Undo snackbar that restores the item', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {'id': 'a', 'name': 'Alpha', 'quantity': 1});
    await db.insert('medications', {'id': 'b', 'name': 'Beta', 'quantity': 1});
    final c = await pumpMedoraApp(
      tester,
      const MedicationListScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.text('Alpha'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    // The "Archived" filter chip is always on screen, so scope the check to
    // the SnackBar to confirm it's the archive confirmation, not the chip.
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Archived'),
      ),
      findsOneWidget,
    );
    expect(find.text('Alpha'), findsNothing);
    expect(
      (await c.read(
        medicationListProvider.future,
      )).firstWhere((m) => m.id == 'a').isArchived,
      isTrue,
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(
      (await c.read(
        medicationListProvider.future,
      )).firstWhere((m) => m.id == 'a').isArchived,
      isFalse,
    );
  });
}
