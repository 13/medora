import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  final fixedNow = DateTime(2026, 3, 4, 15, 0);
  final today = DateTime(2026, 3, 4);

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
        nowProvider.overrideWithValue(() => fixedNow),
      ];

  testWidgets('groups by time of day, navigates days, take + undo', (tester) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db, medicationName: 'Brufen');
    final morning = await seedDoseLog(db, s.prescriptionId, today.add(const Duration(hours: 8)));   // overdue
    await seedDoseLog(db, s.prescriptionId, today.add(const Duration(hours: 20)));                    // evening
    await seedDoseLog(db, s.prescriptionId, today.add(const Duration(days: 1, hours: 8)));            // tomorrow

    final c = await pumpMedoraApp(tester, const DoseScheduleScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Evening'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.text('Take all due'), findsNothing); // only one dose is due

    // Tomorrow chip: weekday short + day number "5"
    await tester.tap(find.widgetWithText(InkWell, '5').first);
    await tester.pumpAndSettle();
    expect(c.read(selectedDoseDayProvider), today.add(const Duration(days: 1)));
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Evening'), findsNothing);

    await tester.tap(find.widgetWithText(InkWell, '4').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Take').first);
    await tester.pumpAndSettle();
    expect(find.text('Taken'), findsOneWidget);
    final taken = (await c.read(dosesForDayProvider(today).future)).firstWhere((d) => d.id == morning);
    expect(taken.status, DoseStatus.taken);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undone = (await c.read(dosesForDayProvider(today).future)).firstWhere((d) => d.id == morning);
    expect(undone.status, DoseStatus.pending);
  });

  testWidgets('Take all due appears with two due doses and takes both', (tester) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, today.add(const Duration(hours: 8)));
    await seedDoseLog(db, s.prescriptionId, today.add(const Duration(hours: 12)));
    final c = await pumpMedoraApp(tester, const DoseScheduleScreen(), overrides: await overrides());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Take all due'));
    await tester.pumpAndSettle();
    final doses = await c.read(dosesForDayProvider(today).future);
    expect(doses.every((d) => d.status == DoseStatus.taken), isTrue);
  });
}
