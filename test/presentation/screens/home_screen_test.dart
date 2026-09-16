import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/failing_dose_repo.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime.now();
  // getTodaysDoseLogs/DoseMaintenanceService key off the real wall clock
  // (by design), not nowProvider, so every seed below is placed relative
  // to the REAL now via `recentToday`, which clamps to stay on the same
  // calendar day and inside the missed-dose grace window no matter what
  // hour the suite runs at.

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

  testWidgets('Now card shows the next due dose and Take → Undo works', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final overdue = recentToday(now, minutes: 10);
    await seedDoseLog(db, s.prescriptionId, overdue);
    await db.insert('medications', {
      'id': 'exp',
      'name': 'Expiring',
      'quantity': 3,
      'expiry_date': DateTime.now()
          .add(const Duration(days: 5))
          .toIso8601String()
          .split('T')
          .first,
    });

    final c = await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Next dose'), findsOneWidget);
    expect(find.text('Tachipirina'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    // Expiry stat tile shows 1
    final expiringTile = find
        .ancestor(of: find.text('Expiry'), matching: find.byType(InkWell))
        .first;
    expect(
      find.descendant(of: expiringTile, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();
    expect(find.text('Taken'), findsOneWidget); // snackbar
    expect(find.text('Undo'), findsOneWidget);
    expect(c.read(nextDueDoseProvider), isNull);
    expect(find.text('All doses done for today'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Next dose'), findsOneWidget);
    expect(c.read(nextDueDoseProvider)?.medicationName, 'Tachipirina');
  });

  testWidgets(
    'Take resets busy state and reports failure when markDoseTaken fails',
    (tester) async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final overdue = recentToday(now, minutes: 10);
      await seedDoseLog(db, s.prescriptionId, overdue);

      final inner = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
      );
      final failingOverrides = [
        ...await overrides(),
        doseLogRepositoryProvider.overrideWithValue(FailingTakeRepo(inner)),
      ];

      final c = await pumpMedoraApp(
        tester,
        const HomeScreen(),
        overrides: failingOverrides,
      );
      await tester.pumpAndSettle();

      expect(find.text('Tachipirina'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Take'));
      await tester.pumpAndSettle();

      expect(find.text('Something went wrong'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Take'))
            .onPressed,
        isNotNull,
      );
      expect(c.read(nextDueDoseProvider)?.medicationName, 'Tachipirina');
    },
  );

  testWidgets('empty state suggests adding a treatment', (tester) async {
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    expect(find.text('No doses scheduled for today'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add Treatment'), findsOneWidget);
  });

  testWidgets('section headers survive a 2.0x text scale', (tester) async {
    // Phone width: at 800px the Row has slack even at 2.0x.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(db, s.prescriptionId, recentToday(now, minutes: 10));

    await pumpMedoraApp(
      tester,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: HomeScreen(),
      ),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Scroll the section headers into view: at 2.0x the Now card alone
    // fills the viewport, and an overflowing Row only throws once painted.
    await tester.scrollUntilVisible(
      find.text('Active Treatments'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Active Treatments'), findsOneWidget);
    expect(find.text('See All'), findsWidgets);
  });
}
