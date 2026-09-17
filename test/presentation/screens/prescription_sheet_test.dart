import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

/// Host screen with a single button that opens the prescription sheet —
/// mirrors how [TreatmentDetailScreen] invokes it.
class _Host extends ConsumerWidget {
  const _Host({
    required this.treatmentId,
    required this.pickTime,
    this.existingPrescriptionId,
  });

  final String treatmentId;
  final Future<TimeOfDay?> Function(BuildContext, TimeOfDay) pickTime;

  /// When set, the sheet opens in edit mode on that prescription.
  final String? existingPrescriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            Prescription? existing;
            if (existingPrescriptionId != null) {
              existing =
                  (await ref
                          .read(prescriptionRepositoryProvider)
                          .getPrescriptionById(existingPrescriptionId!))
                      .dataOrNull;
            }
            if (!context.mounted) return;
            await showPrescriptionSheet(
              context,
              ref,
              treatmentId: treatmentId,
              existing: existing,
              pickTime: pickTime,
            );
          },
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
        _Host(treatmentId: seeded.treatmentId, pickTime: (_, _) async => null),
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
        _Host(treatmentId: seeded.treatmentId, pickTime: (_, _) async => null),
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

  testWidgets(
    'switching to a unit-less medication drops the amount typed for the previous one',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      // seedPrescription's medication has quantity_unit 'tablets'.
      final seeded = await seedPrescription(db);
      await seedUnitlessMedication(db);

      await pumpMedoraApp(
        tester,
        _Host(treatmentId: seeded.treatmentId, pickTime: (_, _) async => null),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Pick the medication that has a unit and type an amount for it.
      await tester.tap(find.byKey(const Key('medicationDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Tachipirina').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('dosageAmountField')), '2');
      await tester.pumpAndSettle();

      // Switch to the unit-less one: the amount field is replaced by the
      // free-text field, and the stale "2" must not survive into the save.
      await tester.tap(find.byKey(const Key('medicationDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NoUnitMed').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('dosageFreeTextField')),
        '20 gocce',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      final rows = await db.query(
        'prescriptions',
        where: 'treatment_id = ? AND id != ?',
        whereArgs: [seeded.treatmentId, seeded.prescriptionId],
      );
      expect(rows.single['dosage'], '20 gocce');
      expect(rows.single['dosage_amount'], isNull);
    },
  );

  testWidgets(
    'medication dropdown keeps an archived medication that is already selected',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await db.update(
        'medications',
        {'is_archived': 1},
        where: 'id = ?',
        whereArgs: [seeded.medicationId],
      );

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => null,
          existingPrescriptionId: seeded.prescriptionId,
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Editing a prescription whose medication was archived: the archived
      // medication must still be offered, otherwise the dropdown's
      // initialValue matches no item and the selection is silently lost.
      expect(find.textContaining('Tachipirina'), findsWidgets);
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('medicationDropdown')),
      );
      expect(dropdown.initialValue, seeded.medicationId);
    },
  );

  group('as needed', () {
    Future<void> openSheet(
      WidgetTester tester,
      String treatmentId, {
      String? existingPrescriptionId,
      Locale locale = const Locale('en'),
    }) async {
      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: treatmentId,
          pickTime: (_, _) async => null,
          existingPrescriptionId: existingPrescriptionId,
        ),
        overrides: await overrides(),
        locale: locale,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('hides interval, preview and duration, and saves a '
        'prescription that generates no doses', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await openSheet(tester, seeded.treatmentId);

      expect(find.byKey(const Key('intervalHoursField')), findsOneWidget);
      expect(find.byKey(const Key('durationDaysField')), findsOneWidget);

      await tester.tap(find.text('As Needed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('intervalHoursField')), findsNothing);
      expect(find.byKey(const Key('durationDaysField')), findsNothing);
      expect(find.textContaining('Doses at'), findsNothing);
      expect(find.text('Select at least one time'), findsNothing);

      await tester.tap(find.byKey(const Key('medicationDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Tachipirina').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('dosageAmountField')), '1');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      final rows = await db.query(
        'prescriptions',
        where: 'treatment_id = ? AND id != ?',
        whereArgs: [seeded.treatmentId, seeded.prescriptionId],
      );
      expect(rows.single['schedule_type'], 'as_needed');
      expect(rows.single['schedule_times'], isNull);
      // A zero duration: an older build, which reads the type as a fixed
      // interval, generates no doses for it either.
      expect(rows.single['duration_days'], 0);
      expect(
        await db.query(
          'dose_logs',
          where: 'prescription_id = ?',
          whereArgs: [rows.single['id']],
        ),
        isEmpty,
      );
    });

    testWidgets('an empty duration does not block saving', (tester) async {
      // The hidden fields are unmounted, so their validators cannot run.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await openSheet(tester, seeded.treatmentId);

      await tester.enterText(find.byKey(const Key('intervalHoursField')), '');
      await tester.enterText(find.byKey(const Key('durationDaysField')), '');
      await tester.tap(find.text('As Needed'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('medicationDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Tachipirina').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('dosageAmountField')), '1');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      final rows = await db.query(
        'prescriptions',
        where: 'treatment_id = ? AND id != ?',
        whereArgs: [seeded.treatmentId, seeded.prescriptionId],
      );
      expect(rows.single['schedule_type'], 'as_needed');
      // The NOT NULL columns keep a value: the interval its default, the
      // duration zero.
      expect(rows.single['interval_hours'], 8);
      expect(rows.single['duration_days'], 0);
    });

    testWidgets('switching a scheduled prescription to as needed drops its '
        'pending doses and keeps the taken ones', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final taken = await seedDoseLog(
        db,
        seeded.prescriptionId,
        DateTime(2026, 3, 1, 8),
        status: 'taken',
        takenTime: DateTime(2026, 3, 1, 8, 5),
      );
      await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 16));

      await openSheet(
        tester,
        seeded.treatmentId,
        existingPrescriptionId: seeded.prescriptionId,
      );
      await tester.tap(find.text('As Needed'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Update'));
      await tester.pumpAndSettle();

      final p = await db.query(
        'prescriptions',
        where: 'id = ?',
        whereArgs: [seeded.prescriptionId],
      );
      expect(p.single['schedule_type'], 'as_needed');
      expect(p.single['duration_days'], 0);
      final doses = await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [seeded.prescriptionId],
      );
      expect(doses.map((d) => d['id']), [taken]);
    });

    testWidgets('switching back to a schedule starts it now, for a week '
        'unless the user enters another duration', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final monthAgo = DateTime.now().subtract(const Duration(days: 30));
      final seeded = await seedPrescription(
        db,
        startTime: monthAgo,
        durationDays: 0,
        scheduleType: 'as_needed',
      );
      final before = DateTime.now().subtract(const Duration(minutes: 1));

      await openSheet(
        tester,
        seeded.treatmentId,
        existingPrescriptionId: seeded.prescriptionId,
      );
      await tester.tap(find.text('Fixed Interval'));
      await tester.pumpAndSettle();

      // The stored zero is no duration: the field offers the usual week.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('durationDaysField')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '7',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Update'));
      await tester.pumpAndSettle();

      final p = (await db.query(
        'prescriptions',
        where: 'id = ?',
        whereArgs: [seeded.prescriptionId],
      )).single;
      expect(p['schedule_type'], 'fixed_interval');
      expect(p['duration_days'], 7);
      expect(
        DateTime.parse(p['start_time']! as String).isBefore(before),
        isFalse,
      );
      final doses = await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [seeded.prescriptionId],
      );
      expect(doses, hasLength(21));
      for (final dose in doses) {
        expect(
          DateTime.parse(dose['scheduled_time']! as String).isBefore(before),
          isFalse,
          reason: 'no dose before the switch',
        );
      }
    });

    group('layout at 360 dp', () {
      setUpAll(loadAppFonts);

      for (final locale in const ['de', 'it', 'en']) {
        testWidgets('the three schedule segments stay whole in $locale at '
            '1.6x', (tester) async {
          usePhone(tester);
          // The sheet is pushed above the host, so only an app-wide scale
          // reaches it.
          tester.platformDispatcher.textScaleFactorTestValue = 1.6;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          final db = await AppDatabase.instance.database;
          final seeded = await seedPrescription(db);
          await openSheet(tester, seeded.treatmentId, locale: Locale(locale));
          expect(tester.takeException(), isNull);

          final l10n = lookupAppLocalizations(Locale(locale));
          final segments = find.byType(SegmentedButton<String>);
          expect(
            MediaQuery.textScalerOf(tester.element(segments)).scale(1),
            1.6,
          );
          final sheet = tester.getRect(find.byType(DraggableScrollableSheet));
          for (final label in [
            l10n.fixedInterval,
            l10n.timesPerDay,
            l10n.scheduleAsNeeded,
          ]) {
            final text = find.descendant(
              of: segments,
              matching: find.text(label),
            );
            expect(text, findsOneWidget);
            final fit = measureText(tester, text);
            expect(
              fit.minIntrinsic,
              lessThanOrEqualTo(fit.maxWidth + 0.5),
              reason: '"$label" is broken mid-word: $fit',
            );
            expect(fit.exceeded, isFalse, reason: '"$label" is cut: $fit');
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)),
            );
            expect(
              paragraph.softWrap || fit.maxIntrinsic <= fit.maxWidth + 0.5,
              isTrue,
              reason: '"$label" does not wrap and is cut: $fit',
            );
            final rect = tester.getRect(text);
            expect(
              sheet.contains(rect.topLeft) && sheet.contains(rect.bottomRight),
              isTrue,
              reason: '"$label" at $rect lies outside the sheet $sheet',
            );
          }

          // Every segment can still be chosen.
          await tester.tap(
            find.descendant(
              of: segments,
              matching: find.text(l10n.scheduleAsNeeded),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('durationDaysField')), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}
