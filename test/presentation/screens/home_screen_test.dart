import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.desktop),
      ];

  testWidgets('Now card shows the next due dose and Take → Undo works', (tester) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db, medicationName: 'Tachipirina');
    final overdue = DateTime.now().subtract(const Duration(minutes: 10));
    await seedDoseLog(db, s.prescriptionId, overdue);
    await db.insert('medications', {
      'id': 'exp', 'name': 'Expiring', 'quantity': 3,
      'expiry_date': DateTime.now().add(const Duration(days: 5)).toIso8601String().split('T').first,
    });

    final c = await pumpMedoraApp(tester, const HomeScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    expect(find.text('Next dose'), findsOneWidget);
    expect(find.text('Tachipirina'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    // Expiring stat tile shows 1
    final expiringTile = find.ancestor(of: find.text('Expiring'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: expiringTile, matching: find.text('1')), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();
    expect(find.text('Taken'), findsOneWidget);          // snackbar
    expect(find.text('Undo'), findsOneWidget);
    expect(c.read(nextDueDoseProvider), isNull);
    expect(find.text('All doses done for today'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Next dose'), findsOneWidget);
    expect(c.read(nextDueDoseProvider)?.medicationName, 'Tachipirina');
  });

  testWidgets('empty state suggests adding a treatment', (tester) async {
    await pumpMedoraApp(tester, const HomeScreen(), overrides: await overrides());
    await tester.pumpAndSettle();
    expect(find.text('No doses scheduled for today'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add Treatment'), findsOneWidget);
  });
}
