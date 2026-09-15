import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Forwards every call to [inner] except [markDoseTaken], which waits on
/// [completer] first — used to keep a dose "in flight" so a widget test can
/// assert on the busy UI state.
class _SlowRepo implements DoseLogRepository {
  _SlowRepo(this.inner, this.completer);

  final DoseLogRepositoryImpl inner;
  final Completer<void> completer;

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) async {
    await completer.future;
    return inner.markDoseTaken(id);
  }

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByPrescription(
    String prescriptionId,
  ) => inner.getDoseLogsByPrescription(prescriptionId);

  @override
  Future<Result<DoseLog>> getDoseLogById(String id) => inner.getDoseLogById(id);

  @override
  Future<Result<List<DoseLog>>> getTodaysDoseLogs() =>
      inner.getTodaysDoseLogs();

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  ) => inner.getDoseLogsByDateRange(start, end);

  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(
    DateTime start,
    DateTime end,
  ) => inner.getPendingDoseLogsBetween(start, end);

  @override
  Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff) =>
      inner.markOverduePendingAsMissed(cutoff);

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) =>
      inner.addDoseLog(doseLog);

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) =>
      inner.markDoseSkipped(id);

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) => inner.markDoseMissed(id);

  @override
  Future<Result<DoseLog>> markDosePending(String id) =>
      inner.markDosePending(id);

  @override
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
    String prescriptionId,
  ) => inner.generateDoseLogsForPrescription(prescriptionId);

  @override
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
    String prescriptionId,
  ) => inner.regenerateDoseLogsForPrescription(prescriptionId);
}

void main() {
  final fixedNow = DateTime(2026, 3, 4, 15);
  final today = DateTime(2026, 3, 4);

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
    nowProvider.overrideWithValue(() => fixedNow),
  ];

  testWidgets('groups by time of day, navigates days, take + undo', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db, medicationName: 'Brufen');
    final morning = await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 8)),
    ); // overdue
    await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 20)),
    ); // evening
    await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(days: 1, hours: 8)),
    ); // tomorrow

    final c = await pumpMedoraApp(
      tester,
      const DoseScheduleScreen(),
      overrides: await overrides(),
    );
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
    expect(
      find.descendant(of: find.byType(SnackBar), matching: find.text('Taken')),
      findsOneWidget,
    );
    final taken = (await c.read(
      dosesForDayProvider(today).future,
    )).firstWhere((d) => d.id == morning);
    expect(taken.status, DoseStatus.taken);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undone = (await c.read(
      dosesForDayProvider(today).future,
    )).firstWhere((d) => d.id == morning);
    expect(undone.status, DoseStatus.pending);
  });

  testWidgets('Take all due appears with two due doses and takes both', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 8)),
    );
    await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 12)),
    );
    final c = await pumpMedoraApp(
      tester,
      const DoseScheduleScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Take all due'));
    await tester.pumpAndSettle();
    final doses = await c.read(dosesForDayProvider(today).future);
    expect(doses.every((d) => d.status == DoseStatus.taken), isTrue);
  });

  testWidgets('Skip shows an undo snackbar and undo restores pending', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db, medicationName: 'Brufen');
    final id = await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 8)),
    );

    final c = await pumpMedoraApp(
      tester,
      const DoseScheduleScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Skip'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Skipped'),
      ),
      findsOneWidget,
    );
    final skipped = (await c.read(
      dosesForDayProvider(today).future,
    )).firstWhere((d) => d.id == id);
    expect(skipped.status, DoseStatus.skipped);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undone = (await c.read(
      dosesForDayProvider(today).future,
    )).firstWhere((d) => d.id == id);
    expect(undone.status, DoseStatus.pending);
  });

  testWidgets(
    'busy dose disables its Take button while the action is in flight',
    (tester) async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, medicationName: 'Brufen');
      await seedDoseLog(
        db,
        s.prescriptionId,
        today.add(const Duration(hours: 8)),
      );

      final completer = Completer<void>();
      await pumpMedoraApp(
        tester,
        const DoseScheduleScreen(),
        overrides: [
          ...await overrides(),
          doseLogRepositoryProvider.overrideWith(
            (ref) => _SlowRepo(
              DoseLogRepositoryImpl(
                localDatasource: ref.watch(doseLogLocalDatasourceProvider),
                remoteDatasource: ref.watch(doseLogDatasourceProvider),
                prescriptionLocal: ref.watch(
                  prescriptionLocalDatasourceProvider,
                ),
              ),
              completer,
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Take').first);
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Take').first,
      );
      expect(button.onPressed, isNull);

      completer.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('dose cards render the localized unit label, never the raw key', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    // seedPrescription stores quantity_unit 'tablets' + dosage_amount 1.
    final s = await seedPrescription(db, medicationName: 'Brufen');
    await seedDoseLog(
      db,
      s.prescriptionId,
      today.add(const Duration(hours: 8)),
    );

    await pumpMedoraApp(
      tester,
      const DoseScheduleScreen(),
      overrides: await overrides(),
      locale: const Locale('it'),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 Compresse'), findsOneWidget);
    expect(find.textContaining('tablets'), findsNothing);
  });
}
