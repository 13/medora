import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Host screen with a single button that opens the prescription sheet —
/// mirrors how [TreatmentDetailScreen] invokes it.
class _Host extends ConsumerWidget {
  const _Host({required this.treatmentId, required this.pickTime});

  final String treatmentId;
  final Future<TimeOfDay?> Function(BuildContext, TimeOfDay) pickTime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showPrescriptionSheet(
            context,
            ref,
            treatmentId: treatmentId,
            pickTime: pickTime,
          ),
          child: const Text('Open'),
        ),
      ),
    );
  }
}

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
    reminderPortProvider.overrideWithValue(FakePort()),
  ];

  /// Inserts a medication with no `quantity_unit`, so the sheet renders the
  /// free-text dosage field instead of the amount+unit pair.
  Future<String> seedUnitlessMedication(Database db) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    await db.insert('medications', {
      'id': id,
      'name': 'NoUnitMed',
      'quantity': 5,
      'minimum_stock_level': 0,
      'created_at': now,
      'updated_at': now,
      'sync_status': 'synced',
    });
    return id;
  }

  testWidgets(
    'medication dropdown: no error before Add, validator error appears after Add with nothing selected',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => const TimeOfDay(hour: 7, minute: 30),
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final dropdownText = find.descendant(
        of: find.byType(DropdownButtonFormField<String>),
        matching: find.text('Select Medication'),
      );

      // Before Save: only the placeholder hint renders, no validator error.
      expect(dropdownText, findsOneWidget);

      // Tap Save — medication is required.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pump();

      // After Save: the hint plus the validator error both read the text.
      expect(dropdownText, findsNWidgets(2));
    },
  );

  testWidgets(
    'times-per-day: empty selection shows "select a time" error; a preset chip clears it',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => const TimeOfDay(hour: 7, minute: 30),
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Switch to times-per-day schedule; no times selected yet.
      await tester.tap(find.text('Times per Day'));
      await tester.pumpAndSettle();

      // Tap Save with _selectedTimes empty (medication is also unselected,
      // but we only care about the times-per-day error here).
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pump();

      expect(find.text('Select at least one time'), findsOneWidget);

      // Adding a time via a preset chip clears the stale error immediately
      // (autovalidateMode.onUserInteraction re-runs the validator).
      await tester.tap(find.text('08:00'));
      await tester.pumpAndSettle();

      expect(find.text('Select at least one time'), findsNothing);
    },
  );

  testWidgets(
    'fixed-interval preview shows "Doses at ..." and updates when the interval changes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => null,
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final previewFinder = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('Doses at'),
      );
      expect(previewFinder, findsOneWidget);
      final before = tester.widget<Text>(previewFinder).data!;

      await tester.enterText(find.byKey(const Key('intervalHoursField')), '4');
      await tester.pump();

      final after = tester.widget<Text>(previewFinder).data!;
      expect(after, isNot(equals(before)));
      expect(after, startsWith('Doses at'));
    },
  );

  testWidgets(
    'empty free-text dosage for a unit-less medication shows the required error',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await seedUnitlessMedication(db);

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => null,
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Select the unit-less medication so the free-text dosage field shows.
      await tester.tap(find.byKey(const Key('medicationDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NoUnitMed').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dosageFreeTextField')), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.required), findsOneWidget);
    },
  );
}
