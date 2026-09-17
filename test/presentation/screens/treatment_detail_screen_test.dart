/// The Krankenstand block on the treatment detail screen, and ending the
/// treatment with its sick leave.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:medora/services/export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/failing_dose_repo.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

/// A dose repository whose inserts wait for [release]: a save in flight.
class _HeldAddRepo extends FailingTakeRepo {
  _HeldAddRepo(super.inner, this.release);

  final Future<void> release;

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) => inner.markDoseTaken(id);

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) async {
    await release;
    return inner.addDoseLog(doseLog);
  }
}

/// A dose repository whose treatment read is [read]; everything else is
/// the real one.
class _TreatmentDosesRepo extends FailingTakeRepo {
  _TreatmentDosesRepo(super.inner, this.read);

  final Future<Result<List<DoseLog>>> Function(String treatmentId) read;

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) => inner.markDoseTaken(id);

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByTreatment(String treatmentId) =>
      read(treatmentId);
}

DoseLogRepositoryImpl realDoseRepo() => DoseLogRepositoryImpl(
  localDatasource: DoseLogLocalDatasource(),
  prescriptionLocal: PrescriptionLocalDatasource(),
);

void main() {
  final now = DateTime(2026, 3, 5, 12);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides({
    PlatformCapabilities caps = PlatformCapabilities.desktop,
  }) async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(caps),
    nowProvider.overrideWithValue(() => now),
  ];

  Future<void> seedAndPump(
    WidgetTester tester, {
    DateTime? from,
    DateTime? to,
    String? ref,
    String? doctor,
    Locale locale = const Locale('en'),
    double scale = 1.0,
    Future<void> Function()? beforePump,
    List<Override> extraOverrides = const [],
    PlatformCapabilities caps = PlatformCapabilities.desktop,
    bool active = true,
    List<String> patients = const [],
  }) async {
    await TreatmentLocalDatasource().upsert(
      TreatmentModel(
        id: 't1',
        name: 'Sinusitis',
        startDate: DateTime(2026, 3, 3),
        endDate: active ? null : DateTime(2026, 3, 5),
        isActive: active,
        patientTags: patients,
        sickLeaveFrom: from,
        sickLeaveTo: to,
        sickLeaveRef: ref,
        doctor: doctor,
      ),
      syncStatus: 'synced',
    );
    await beforePump?.call();
    await pumpMedoraApp(
      tester,
      withTextScale(scale, const TreatmentDetailScreen(treatmentId: 't1')),
      overrides: [
        ...await overrides(caps: caps),
        ...extraOverrides,
      ],
      locale: locale,
    );
    await tester.pumpAndSettle();
  }

  /// Scales text app-wide. [withTextScale] only wraps the screen, and a
  /// dialog is pushed on the root navigator above it, so it would not see
  /// that scale.
  void useAppTextScale(WidgetTester tester, double scale) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// The text scale the open dialog is really laid out with.
  double dialogTextScale(WidgetTester tester) => MediaQuery.textScalerOf(
    tester.element(find.byType(AlertDialog)),
  ).scale(1);

  Finder inBlock(Finder f) =>
      find.descendant(of: find.byKey(const Key('sickLeaveBlock')), matching: f);

  testWidgets('a closed sick leave shows its range, length, certificate and '
      'doctor', (tester) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 3),
      to: DateTime(2026, 3, 9),
      ref: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    );

    expect(find.byKey(const Key('sickLeaveBlock')), findsOneWidget);
    expect(inBlock(find.text('Sick leave')), findsOneWidget);
    expect(inBlock(find.text('Mar 3, 2026')), findsOneWidget);
    expect(inBlock(find.text('Mar 9, 2026')), findsOneWidget);
    expect(inBlock(find.text('7 days')), findsOneWidget);
    expect(inBlock(find.text('1234567890')), findsOneWidget);
    expect(inBlock(find.text('Dr. Rossi, Bozen')), findsOneWidget);
  });

  testWidgets('an open sick leave counts up to today and reads "Ongoing"', (
    tester,
  ) async {
    await seedAndPump(tester, from: DateTime(2026, 3, 3));
    expect(inBlock(find.text('Ongoing')), findsOneWidget);
    expect(inBlock(find.text('3 days')), findsOneWidget);
  });

  testWidgets('a one-day leave reads "1 day"', (tester) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 4),
      to: DateTime(2026, 3, 4),
    );
    expect(inBlock(find.text('1 day')), findsOneWidget);
  });

  testWidgets('an open leave that has not started shows no length', (
    tester,
  ) async {
    await seedAndPump(tester, from: DateTime(2026, 3, 10));
    expect(tester.takeException(), isNull);
    expect(inBlock(find.text('Mar 10, 2026')), findsOneWidget);
    expect(inBlock(find.text('Duration')), findsNothing);
  });

  testWidgets('a leave that ends before it starts shows no length', (
    tester,
  ) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 9),
      to: DateTime(2026, 3, 3),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('sickLeaveBlock')), findsOneWidget);
    expect(inBlock(find.text('Duration')), findsNothing);
  });

  testWidgets('a doctor alone shows the block without sick-leave rows', (
    tester,
  ) async {
    await seedAndPump(tester, doctor: 'Dr. Rossi');
    expect(inBlock(find.text('Dr. Rossi')), findsOneWidget);
    expect(inBlock(find.text('Doctor')), findsOneWidget);
    expect(inBlock(find.text('Unable to work from')), findsNothing);
    // No leave was recorded, so the card does not claim one.
    expect(inBlock(find.text('Sick leave')), findsNothing);
  });

  testWidgets('a certificate number alone shows the block with that row', (
    tester,
  ) async {
    // The certificate can arrive before the dates are known; the form saves
    // the number on its own, so the detail screen has to show it.
    await seedAndPump(tester, ref: '9999');
    expect(find.byKey(const Key('sickLeaveBlock')), findsOneWidget);
    expect(inBlock(find.text('Sick leave')), findsOneWidget);
    expect(inBlock(find.text('Certificate no.')), findsOneWidget);
    expect(inBlock(find.text('9999')), findsOneWidget);
    expect(inBlock(find.text('Unable to work from')), findsNothing);
    expect(inBlock(find.text('Unable to work until')), findsNothing);
    expect(inBlock(find.text('Ongoing')), findsNothing);
    expect(inBlock(find.text('Duration')), findsNothing);
    expect(inBlock(find.text('Doctor')), findsNothing);
  });

  testWidgets('an end date alone shows the block with only that date', (
    tester,
  ) async {
    // Not reachable from the form, but a synced or restored row can carry
    // it, and a stored value should never be invisible.
    await seedAndPump(tester, to: DateTime(2026, 3, 9));
    expect(inBlock(find.text('Sick leave')), findsOneWidget);
    expect(inBlock(find.text('Unable to work until')), findsOneWidget);
    expect(inBlock(find.text('Mar 9, 2026')), findsOneWidget);
    expect(inBlock(find.text('Unable to work from')), findsNothing);
    expect(inBlock(find.text('Duration')), findsNothing);
  });

  testWidgets('the Italian heading reads "Assenza per malattia", so '
      '"Malattia" names only the illness', (tester) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 3),
      locale: const Locale('it'),
    );
    expect(inBlock(find.text('Assenza per malattia')), findsOneWidget);
    expect(inBlock(find.text('Malattia')), findsNothing);
  });

  testWidgets('a treatment without sick leave or doctor has no block', (
    tester,
  ) async {
    await seedAndPump(tester);
    expect(find.text('Sinusitis'), findsWidgets);
    expect(find.byKey(const Key('sickLeaveBlock')), findsNothing);
  });

  group('ending the treatment', () {
    final checkbox = find.byKey(const Key('endSickLeaveCheckbox'));
    final dialog = find.byType(AlertDialog);

    Future<void> openEndDialog(
      WidgetTester tester, {
      String label = 'End Treatment',
    }) async {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
    }

    Future<void> confirm(
      WidgetTester tester, {
      String label = 'End Treatment',
    }) async {
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, label),
        ),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    }

    Future<TreatmentModel> stored() async =>
        (await TreatmentLocalDatasource().getTreatmentById('t1'))!;

    testWidgets('an open leave is offered unticked, with the date it would '
        'end on; ticking it closes the leave today', (tester) async {
      await seedAndPump(tester, from: DateTime(2026, 3, 3));
      // The date the dialog promises is the one the domain rule stores.
      final endsOn = Treatment(
        id: 't1',
        name: 'Sinusitis',
        startDate: DateTime(2026, 3, 3),
        sickLeaveFrom: DateTime(2026, 3, 3),
      ).sickLeaveEndAt(now);
      expect(endsOn, DateTime(2026, 3, 5));
      await openEndDialog(tester);

      // "until" and the date: today still counts as a day of the leave.
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Also end sick leave today (until Mar 5, 2026)'),
        ),
        findsOneWidget,
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await tester.tap(checkbox);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);

      await confirm(tester);
      final t = await stored();
      expect(t.isActive, isFalse);
      expect(t.sickLeaveTo, endsOn);
      // The screen shows the closed leave straight away.
      expect(inBlock(find.text('Ongoing')), findsNothing);
      expect(inBlock(find.text('Mar 5, 2026')), findsOneWidget);
    });

    testWidgets('left unticked, the box ends the treatment and keeps the '
        'leave open', (tester) async {
      // A leave closed by mistake would change the record silently; one
      // left open stays visible, since its badge keeps counting.
      await seedAndPump(tester, from: DateTime(2026, 3, 3));
      await openEndDialog(tester);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);

      await confirm(tester);
      final t = await stored();
      expect(t.isActive, isFalse);
      expect(t.sickLeaveTo, isNull);
    });

    for (final locale in const ['en', 'de', 'it']) {
      testWidgets('a failed End says so and leaves the treatment running '
          '($locale)', (tester) async {
        await seedAndPump(
          tester,
          locale: Locale(locale),
          extraOverrides: [
            treatmentRepositoryProvider.overrideWithValue(
              _EndFails(localDatasource: TreatmentLocalDatasource()),
            ),
          ],
        );
        final l10n = lookupAppLocalizations(Locale(locale));
        await openEndDialog(tester, label: l10n.endTreatment);
        await confirm(tester, label: l10n.endTreatment);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(l10n.endTreatmentFailed),
          ),
          findsOneWidget,
        );
        // Only the fixed message: never the repository's technical text.
        expect(find.textContaining('disk full'), findsNothing);
        expect((await stored()).isActive, isTrue);
      });
    }

    testWidgets('cancelling changes nothing', (tester) async {
      await seedAndPump(tester, from: DateTime(2026, 3, 3));
      await openEndDialog(tester);
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      final t = await stored();
      expect(t.isActive, isTrue);
      expect(t.sickLeaveTo, isNull);
    });

    testWidgets('without a leave the dialog has no box and still ends the '
        'treatment', (tester) async {
      await seedAndPump(tester);
      await openEndDialog(tester);
      expect(checkbox, findsNothing);
      expect(find.textContaining('Also end sick leave'), findsNothing);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(
            'End "Sinusitis"? No new doses or reminders will be created for '
            'its medicines, and no further doses can be logged. Doses already '
            'recorded are kept.',
          ),
        ),
        findsOneWidget,
      );

      await confirm(tester);
      final t = await stored();
      expect(t.isActive, isFalse);
      expect(t.sickLeaveFrom, isNull);
      expect(t.sickLeaveTo, isNull);
    });

    testWidgets('a closed leave is not offered and not moved', (tester) async {
      await seedAndPump(
        tester,
        from: DateTime(2026, 3, 3),
        to: DateTime(2026, 3, 4),
      );
      await openEndDialog(tester);
      expect(checkbox, findsNothing);

      await confirm(tester);
      final t = await stored();
      expect(t.isActive, isFalse);
      expect(t.sickLeaveTo, DateTime(2026, 3, 4));
    });

    testWidgets('a leave that has not started yet is not offered', (
      tester,
    ) async {
      await seedAndPump(tester, from: DateTime(2026, 3, 6));
      await openEndDialog(tester);
      expect(checkbox, findsNothing);

      await confirm(tester);
      final t = await stored();
      expect(t.isActive, isFalse);
      expect(t.sickLeaveTo, isNull);
    });

    for (final (locale, label, message) in const [
      (
        'de',
        'Behandlung beenden',
        '"Sinusitis" beenden? Für die Medikamente dieser Behandlung werden '
            'keine neuen Dosen und Erinnerungen mehr angelegt, und es lassen '
            'sich keine weiteren Dosen eintragen. Bereits eingetragene Dosen '
            'bleiben erhalten.',
      ),
      (
        'it',
        'Termina trattamento',
        'Terminare "Sinusitis"? Per i farmaci di questo trattamento non '
            'verranno più pianificate dosi né inviati promemoria, e non si '
            'potranno registrare altre dosi. Le dosi già registrate restano '
            'salvate.',
      ),
    ]) {
      testWidgets('the $locale message says what ending does (review I-3)', (
        tester,
      ) async {
        await seedAndPump(tester, locale: Locale(locale));
        await openEndDialog(tester, label: label);
        expect(
          find.descendant(of: dialog, matching: find.text(message)),
          findsOneWidget,
        );
      });
    }

    testWidgets('German reads "Krankenstand heute ebenfalls beenden (bis '
        '5. März 2026)"', (tester) async {
      await seedAndPump(
        tester,
        from: DateTime(2026, 3, 3),
        locale: const Locale('de'),
      );
      await openEndDialog(tester, label: 'Behandlung beenden');
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(
            'Krankenstand heute ebenfalls beenden (bis 5. März 2026)',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(checkbox);
      await tester.pump();
      await confirm(tester, label: 'Behandlung beenden');
      expect((await stored()).sickLeaveTo, DateTime(2026, 3, 5));
    });
  });

  group('layout at 360 dp', () {
    setUpAll(loadAppFonts);

    for (final locale in const ['de', 'it', 'en']) {
      testWidgets('every row of the block stays whole in $locale at 1.6x', (
        tester,
      ) async {
        usePhone(tester);
        await seedAndPump(
          tester,
          from: DateTime(2026, 3, 3),
          to: DateTime(2026, 3, 29),
          ref: '1234567890',
          doctor: 'Dr. Rossi, Bozen',
          locale: Locale(locale),
          scale: 1.6,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('sickLeaveBlock')),
          100,
        );

        final texts = inBlock(find.byType(Text));
        final count = texts.evaluate().length;
        expect(count, greaterThanOrEqualTo(11));
        for (var i = 0; i < count; i++) {
          final text = texts.at(i);
          final data = tester.widget<Text>(text).data;
          final fit = measureText(tester, text);
          expect(
            fit.minIntrinsic,
            lessThanOrEqualTo(fit.maxWidth + 0.5),
            reason: '"$data" is broken mid-word: $fit',
          );
        }
      });
    }

    for (final locale in const ['de', 'it', 'en']) {
      testWidgets('the End dialog stays whole in $locale at 1.6x', (
        tester,
      ) async {
        usePhone(tester);
        useAppTextScale(tester, 1.6);
        await seedAndPump(
          tester,
          from: DateTime(2026, 3, 3),
          locale: Locale(locale),
        );
        final l10n = lookupAppLocalizations(Locale(locale));
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.endTreatment).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(dialogTextScale(tester), 1.6);

        final dialog = find.byType(AlertDialog);
        // The dialog's card, not the full-screen route it sits in.
        final dialogBox = tester.getRect(
          find.descendant(of: dialog, matching: find.byType(Material)).first,
        );
        // Intl.defaultLocale is the test's locale here, as in the app.
        final label = find.text(
          l10n.sickLeaveEndToday(DateTime(2026, 3, 5).formatted),
        );
        expect(label, findsOneWidget);
        final texts = find.descendant(of: dialog, matching: find.byType(Text));
        final count = texts.evaluate().length;
        // Title, message, checkbox label, two buttons.
        expect(count, 5);
        for (var i = 0; i < count; i++) {
          final text = texts.at(i);
          final data = tester.widget<Text>(text).data;
          final fit = measureText(tester, text);
          expect(
            fit.minIntrinsic,
            lessThanOrEqualTo(fit.maxWidth + 0.5),
            reason: '"$data" is broken mid-word: $fit',
          );
          expect(fit.exceeded, isFalse, reason: '"$data" is cut: $fit');
          // A line that may not wrap is cut at the edge without a trace.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: text, matching: find.byType(RichText)),
          );
          expect(
            paragraph.softWrap || fit.maxIntrinsic <= fit.maxWidth + 0.5,
            isTrue,
            reason: '"$data" does not wrap and is cut: $fit',
          );
          final rect = tester.getRect(text);
          expect(
            dialogBox.contains(rect.topLeft) &&
                dialogBox.contains(rect.bottomRight),
            isTrue,
            reason: '"$data" at $rect lies outside the dialog $dialogBox',
          );
        }
        // The box and the confirm button are still reachable.
        await tester.tap(find.byKey(const Key('endSickLeaveCheckbox')));
        await tester.pump();
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.widgetWithText(TextButton, l10n.endTreatment),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          (await TreatmentLocalDatasource().getTreatmentById(
            't1',
          ))!.sickLeaveTo,
          DateTime(2026, 3, 5),
        );
      });
    }

    testWidgets('the End dialog scrolls instead of overflowing on a phone '
        'held sideways', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      useAppTextScale(tester, 1.6);
      await seedAndPump(
        tester,
        from: DateTime(2026, 3, 3),
        locale: const Locale('de'),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Behandlung beenden').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(dialogTextScale(tester), 1.6);

      final checkbox = find.byKey(const Key('endSickLeaveCheckbox'));
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    });
  });

  group('an as-needed prescription', () {
    final logButton = find.byKey(const Key('logDose_p1'));

    /// Seeds Ibuprofen (10 tablets) and prescription `p1` for treatment t1.
    Future<void> seedPrescription({
      String scheduleType = 'as_needed',
      bool isActive = true,
      bool autoDiminish = false,
    }) async {
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {
        'id': 'm1',
        'name': 'Ibuprofen',
        'quantity': 10,
        'quantity_unit': 'tablets',
        'minimum_stock_level': 0,
        'created_at': '2026-03-01T08:00:00.000',
        'updated_at': '2026-03-01T08:00:00.000',
        'sync_status': 'synced',
      });
      await db.insert('prescriptions', {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        // As the sheet saves it: the medication's own unit, as its raw key.
        'dosage': '1 tablets',
        'dosage_amount': 1.0,
        'interval_hours': 8,
        'duration_days': 7,
        'start_time': '2026-03-03T08:00:00.000',
        'is_active': isActive ? 1 : 0,
        'auto_diminish': autoDiminish ? 1 : 0,
        'schedule_type': scheduleType,
        'created_at': '2026-03-03T08:00:00.000',
        'updated_at': '2026-03-03T08:00:00.000',
        'sync_status': 'synced',
      });
    }

    Future<List<Map<String, Object?>>> doses() async =>
        (await AppDatabase.instance.database).query(
          'dose_logs',
          where: 'prescription_id = ?',
          whereArgs: ['p1'],
        );

    testWidgets('reads "As Needed" instead of an interval and duration', (
      tester,
    ) async {
      await seedAndPump(tester, beforePump: seedPrescription);
      expect(find.text('1 tablet · As Needed'), findsOneWidget);
      expect(find.textContaining('every'), findsNothing);
      expect(logButton, findsOneWidget);
      expect(
        find.descendant(of: logButton, matching: find.text('Log dose')),
        findsOneWidget,
      );
    });

    testWidgets('"Log dose" records one taken dose at the app clock and says '
        'so', (tester) async {
      await seedAndPump(
        tester,
        beforePump: () => seedPrescription(autoDiminish: true),
      );

      await tester.tap(logButton);
      await tester.pumpAndSettle();

      final rows = await doses();
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'taken');
      expect(DateTime.parse(rows.single['taken_time']! as String), now);
      expect(DateTime.parse(rows.single['scheduled_time']! as String), now);
      expect(find.text('Dose logged'), findsOneWidget);
      // The stock path of a tapped dose ran too.
      final med = await (await AppDatabase.instance.database).query(
        'medications',
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      expect(med.single['quantity'], 9);

      // A second intake is a second dose.
      await tester.tap(logButton);
      await tester.pumpAndSettle();
      expect(await doses(), hasLength(2));
    });

    testWidgets('a double tap logs one dose, and the button waits for it', (
      tester,
    ) async {
      final release = Completer<void>();
      await seedAndPump(
        tester,
        beforePump: () => seedPrescription(autoDiminish: true),
        extraOverrides: [
          doseLogRepositoryProvider.overrideWithValue(
            _HeldAddRepo(
              DoseLogRepositoryImpl(
                localDatasource: DoseLogLocalDatasource(),
                prescriptionLocal: PrescriptionLocalDatasource(),
              ),
              release.future,
            ),
          ),
        ],
      );

      // Two taps before the first one has been saved.
      await tester.tap(logButton);
      await tester.tap(logButton);
      await tester.pump();
      expect(tester.widget<TextButton>(logButton).onPressed, isNull);
      release.complete();
      await tester.pumpAndSettle();

      expect(await doses(), hasLength(1));
      final med = await (await AppDatabase.instance.database).query(
        'medications',
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      expect(med.single['quantity'], 9);
      expect(find.text('Dose logged'), findsOneWidget);
      expect(tester.widget<TextButton>(logButton).onPressed, isNotNull);
    });

    testWidgets('"Undo" on the snackbar removes the dose and gives the '
        'stock back', (tester) async {
      await seedAndPump(
        tester,
        beforePump: () => seedPrescription(autoDiminish: true),
      );
      await tester.tap(logButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();

      final rows = await doses();
      expect(rows.single['sync_status'], 'pending_delete');
      final med = await (await AppDatabase.instance.database).query(
        'medications',
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      expect(med.single['quantity'], 10);
    });

    testWidgets('German reads "Bei Bedarf" and "Dosis eintragen"', (
      tester,
    ) async {
      await seedAndPump(
        tester,
        beforePump: seedPrescription,
        locale: const Locale('de'),
      );
      expect(find.text('1 Tablette · Bei Bedarf'), findsOneWidget);
      await tester.tap(find.text('Dosis eintragen'));
      await tester.pumpAndSettle();
      expect(find.text('Dosis eingetragen'), findsOneWidget);
    });

    testWidgets('a paused one offers no "Log dose"', (tester) async {
      await seedAndPump(
        tester,
        beforePump: () => seedPrescription(isActive: false),
      );
      expect(find.text('1 tablet · As Needed'), findsOneWidget);
      expect(logButton, findsNothing);
    });

    testWidgets('an ended episode offers no "Log dose", and its prescription '
        'stays active (review I-3)', (tester) async {
      await seedAndPump(tester, active: false, beforePump: seedPrescription);
      expect(find.text('1 tablet · As Needed'), findsOneWidget);
      expect(logButton, findsNothing);
      expect(find.text('Log dose'), findsNothing);
      final stored = await (await AppDatabase.instance.database).query(
        'prescriptions',
      );
      expect(stored.single['is_active'], 1);
    });

    testWidgets('a scheduled one offers no "Log dose"', (tester) async {
      await seedAndPump(
        tester,
        beforePump: () => seedPrescription(scheduleType: 'fixed_interval'),
      );
      expect(find.text('1 tablet · every 8h · 7 days'), findsOneWidget);
      expect(logButton, findsNothing);
      expect(find.text('Log dose'), findsNothing);
    });

    group('layout at 360 dp', () {
      setUpAll(loadAppFonts);

      for (final locale in const ['de', 'it', 'en']) {
        testWidgets('the summary and "Log dose" stay whole in $locale at '
            '1.6x', (tester) async {
          usePhone(tester);
          // App-wide, so the snackbar is scaled as well; the screen's own
          // scale has to match, or its wrapper would reset it to 1.0.
          useAppTextScale(tester, 1.6);
          await seedAndPump(
            tester,
            beforePump: seedPrescription,
            locale: Locale(locale),
            scale: 1.6,
          );
          final l10n = lookupAppLocalizations(Locale(locale));
          await tester.scrollUntilVisible(logButton, 100);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            MediaQuery.textScalerOf(tester.element(logButton)).scale(1),
            1.6,
          );

          final screen = tester.getRect(find.byType(Scaffold).first);
          final card = tester.getRect(
            find.ancestor(of: logButton, matching: find.byType(Card)),
          );
          void expectWhole(Finder text, Rect box) {
            final data = tester.widget<Text>(text).data;
            final fit = measureText(tester, text);
            expect(
              fit.minIntrinsic,
              lessThanOrEqualTo(fit.maxWidth + 0.5),
              reason: '"$data" is broken mid-word: $fit',
            );
            expect(fit.exceeded, isFalse, reason: '"$data" is cut: $fit');
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)),
            );
            expect(
              paragraph.softWrap || fit.maxIntrinsic <= fit.maxWidth + 0.5,
              isTrue,
              reason: '"$data" does not wrap and is cut: $fit',
            );
            final rect = tester.getRect(text);
            expect(
              box.contains(rect.topLeft) && box.contains(rect.bottomRight),
              isTrue,
              reason: '"$data" at $rect lies outside $box',
            );
          }

          expectWhole(
            find.text(
              '1 ${l10n.dosageUnitName(1, 'tablets')} · '
              '${l10n.scheduleAsNeeded}',
            ),
            card,
          );
          final buttonLabel = find.descendant(
            of: logButton,
            matching: find.text(l10n.logDoseNow),
          );
          expectWhole(buttonLabel, card);
          // A button label wrapped onto two lines reads as two buttons.
          final fit = measureText(tester, buttonLabel);
          expect(
            fit.maxIntrinsic,
            lessThanOrEqualTo(fit.maxWidth + 0.5),
            reason: '"${l10n.logDoseNow}" wraps: $fit',
          );

          await tester.tap(logButton);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final snack = find.text(l10n.doseLogged);
          expect(snack, findsOneWidget);
          expectWhole(snack, screen);
          expectWhole(
            find.descendant(
              of: find.byType(SnackBarAction),
              matching: find.text(l10n.undo),
            ),
            screen,
          );
          expect(tester.takeException(), isNull);
        });
      }
    });
  });

  group('what was taken, and sharing the episode', () {
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

    /// The texts handed to the share sheet.
    List<String> captureShares(WidgetTester tester, {List<String>? subjects}) {
      final shared = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        shareChannel,
        (call) async {
          final args = call.arguments as Map;
          shared.add(args['text'] as String);
          subjects?.add(args['subject'] as String);
          return 'dev.fluttercommunity.plus/share/success';
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          shareChannel,
          null,
        ),
      );
      return shared;
    }

    Future<void> insertMedication(String id, String name) async =>
        (await AppDatabase.instance.database).insert('medications', {
          'id': id,
          'name': name,
          'quantity': 10,
          'quantity_unit': 'tablets',
          'minimum_stock_level': 0,
          'created_at': '2026-03-01T08:00:00.000',
          'updated_at': '2026-03-01T08:00:00.000',
          'sync_status': 'synced',
        });

    Future<void> insertPrescription(
      String id, {
      required String medicationId,
      String treatmentId = 't1',
      String scheduleType = 'fixed_interval',
      int durationDays = 7,
      String startTime = '2026-03-03T08:00:00.000',
      String dosage = '1 tablets',
    }) async => (await AppDatabase.instance.database).insert('prescriptions', {
      'id': id,
      'treatment_id': treatmentId,
      'medication_id': medicationId,
      'dosage': dosage,
      'dosage_amount': 1.0,
      'interval_hours': 8,
      'duration_days': durationDays,
      'start_time': startTime,
      'is_active': 1,
      'auto_diminish': 0,
      'schedule_type': scheduleType,
      'created_at': '2026-03-03T08:00:00.000',
      'updated_at': '2026-03-03T08:00:00.000',
      'sync_status': 'synced',
    });

    var doseSeq = 0;
    Future<void> insertDose(
      String prescriptionId,
      DateTime at,
      String status,
    ) async => (await AppDatabase.instance.database).insert('dose_logs', {
      'id': 'dose-${doseSeq++}',
      'prescription_id': prescriptionId,
      'scheduled_time': at.toIso8601String(),
      'taken_time': status == 'taken' ? at.toIso8601String() : null,
      'status': status,
      'created_at': '2026-03-03T08:00:00.000',
      'updated_at': '2026-03-03T08:00:00.000',
      'sync_status': 'synced',
    });

    /// Ibuprofen every 8 h from Mar 3, 08:00 for 7 days (21 doses). By the
    /// test clock (Mar 5, 12:00) seven are due: five taken, one missed and
    /// one still pending, overdue. The other fourteen are still to come.
    Future<void> seedScheduled() async {
      await insertMedication('m1', 'Ibuprofen');
      await insertPrescription('p1', medicationId: 'm1');
      for (var i = 0; i < 21; i++) {
        final at = DateTime(2026, 3, 3, 8).add(Duration(hours: 8 * i));
        await insertDose(
          'p1',
          at,
          i < 5
              ? 'taken'
              : i == 5
              ? 'missed'
              : 'pending',
        );
      }
    }

    /// Tachipirina as needed, taken on Mar 3 and twice on Mar 4.
    Future<void> seedAsNeeded({bool taken = true}) async {
      await insertMedication('m2', 'Tachipirina');
      await insertPrescription(
        'p2',
        medicationId: 'm2',
        scheduleType: 'as_needed',
        durationDays: 0,
        // Listed after the scheduled one, which starts earlier.
        startTime: '2026-03-03T09:00:00.000',
      );
      if (!taken) return;
      await insertDose('p2', DateTime(2026, 3, 3, 21), 'taken');
      await insertDose('p2', DateTime(2026, 3, 4, 9), 'taken');
      await insertDose('p2', DateTime(2026, 3, 4, 15), 'taken');
    }

    /// Another episode with its own medicine and doses.
    Future<void> seedOtherEpisode() async {
      await TreatmentLocalDatasource().upsert(
        TreatmentModel(
          id: 't2',
          name: 'Migräne',
          startDate: DateTime(2026, 2, 2),
          sickLeaveFrom: DateTime(2026, 2, 2),
          doctor: 'Dr. Bianchi',
        ),
        syncStatus: 'synced',
      );
      await insertMedication('m9', 'Sumatriptan');
      await insertPrescription('p9', medicationId: 'm9', treatmentId: 't2');
      await insertDose('p9', DateTime(2026, 3, 3, 8), 'taken');
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a scheduled prescription counts only the doses due so far', (
      tester,
    ) async {
      await seedAndPump(tester, beforePump: seedScheduled);
      expect(find.text('5 of 7 taken'), findsOneWidget);
    });

    testWidgets('an ended treatment expects no more of its doses', (
      tester,
    ) async {
      // The dose still pending from this morning was never going to be
      // taken once the treatment ended.
      await seedAndPump(tester, beforePump: seedScheduled, active: false);
      expect(find.text('5 of 6 taken'), findsOneWidget);
    });

    testWidgets('an as-needed prescription shows how many were taken, and '
        'when', (tester) async {
      await seedAndPump(tester, beforePump: seedAsNeeded);
      // On screen each date keeps together (no-break spaces).
      expect(
        find.text(
          '3 doses taken (Mar\u00A03,\u00A02026\u00A0– Mar\u00A04,\u00A02026)',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(' of '), findsNothing);
    });

    testWidgets('logging a dose updates the count at once', (tester) async {
      await seedAndPump(tester, beforePump: () => seedAsNeeded(taken: false));
      expect(find.text('Not taken'), findsOneWidget);

      await tester.tap(find.byKey(const Key('logDose_p2')));
      await tester.pumpAndSettle();

      expect(find.text('Not taken'), findsNothing);
      expect(find.text('1 dose taken (Mar\u00A05,\u00A02026)'), findsOneWidget);
    });

    testWidgets('German reads "5 von 7 eingenommen"', (tester) async {
      await seedAndPump(
        tester,
        beforePump: seedScheduled,
        locale: const Locale('de'),
      );
      expect(find.text('5 von 7 eingenommen'), findsOneWidget);
    });

    testWidgets('"Share record" hands over this episode, and only this one, '
        'as text', (tester) async {
      final subjects = <String>[];
      final shared = captureShares(tester, subjects: subjects);
      await seedAndPump(
        tester,
        from: DateTime(2026, 3, 3),
        ref: '1234567890',
        doctor: 'Dr. Rossi, Bozen',
        beforePump: () async {
          await seedScheduled();
          await seedAsNeeded();
          await seedOtherEpisode();
        },
      );

      await openMenu(tester);
      await tester.tap(find.text('Share record'));
      await tester.pumpAndSettle();

      expect(shared, [
        'Sinusitis\n'
            'Illness: Mar 3, 2026 – ongoing\n'
            'Sick leave: Mar 3, 2026 – ongoing (Day 3)\n'
            'Certificate no.: 1234567890\n'
            'Doctor: Dr. Rossi, Bozen\n'
            'Medications:\n'
            '- Ibuprofen: 1 tablet · Every 8 hours · 7 days\n'
            '  5 of 7 taken\n'
            '- Tachipirina: 1 tablet · As Needed\n'
            '  3 doses taken (Mar 3, 2026 – Mar 4, 2026)',
      ]);
      // Nobody was named, so there is no patient line.
      expect(shared.single, isNot(contains('Patient')));
      // A mail list or a notification shows the subject: no diagnosis.
      expect(subjects, ['Illness record: Mar 3, 2026 – ongoing']);
    });

    testWidgets('German shares German text, naming who was ill', (
      tester,
    ) async {
      final subjects = <String>[];
      final shared = captureShares(tester, subjects: subjects);
      await seedAndPump(
        tester,
        from: DateTime(2026, 3, 3),
        to: DateTime(2026, 3, 4),
        locale: const Locale('de'),
        patients: const ['Lena'],
        beforePump: seedAsNeeded,
      );

      await openMenu(tester);
      await tester.tap(find.text('Verlauf teilen'));
      await tester.pumpAndSettle();

      expect(shared, [
        'Sinusitis\n'
            'Patient/in: Lena\n'
            'Krankheit: 3. März 2026 – laufend\n'
            'Krankenstand: 3. März 2026 – 4. März 2026 (2 Tage)\n'
            'Medikamente:\n'
            '- Tachipirina: 1 Tablette · Bei Bedarf\n'
            '  3 Dosen eingenommen (3. März 2026 – 4. März 2026)',
      ]);
      expect(subjects, ['Krankheitsverlauf: 3. März 2026 – laufend']);
    });

    testWidgets('Italian shares Italian text, naming who was ill', (
      tester,
    ) async {
      final subjects = <String>[];
      final shared = captureShares(tester, subjects: subjects);
      await seedAndPump(
        tester,
        locale: const Locale('it'),
        patients: const ['Lena', 'Marco'],
        beforePump: () async {
          await seedScheduled();
          await seedAsNeeded();
        },
      );

      await openMenu(tester);
      await tester.tap(find.text('Condividi resoconto'));
      await tester.pumpAndSettle();

      expect(shared, [
        'Sinusitis\n'
            'Paziente: Lena, Marco\n'
            'Malattia: 3 mar 2026 – in corso\n'
            'Farmaci:\n'
            '- Ibuprofen: 1 compressa · Ogni 8 ore · 7 giorni\n'
            '  5 su 7 assunte\n'
            '- Tachipirina: 1 compressa · Al bisogno\n'
            '  3 dosi assunte (3 mar 2026 – 4 mar 2026)',
      ]);
      expect(subjects, ['Decorso della malattia: 3 mar 2026 – in corso']);
    });

    testWidgets('a dose stored without its unit takes the medication\'s, on '
        'the card and in the shared text', (tester) async {
      final shared = captureShares(tester);
      await seedAndPump(
        tester,
        locale: const Locale('it'),
        beforePump: () async {
          await insertMedication('m1', 'Ibuprofen');
          await insertPrescription('p1', medicationId: 'm1', dosage: '1');
        },
      );
      expect(find.text('1 compressa · ogni 8h · 7 giorni'), findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text('Condividi resoconto'));
      await tester.pumpAndSettle();
      expect(
        shared.single,
        contains('- Ibuprofen: 1 compressa · Ogni 8 ore · 7 giorni'),
      );
    });

    testWidgets('the card reads the unit in German too', (tester) async {
      await seedAndPump(
        tester,
        locale: const Locale('de'),
        beforePump: seedScheduled,
      );
      expect(find.text('1 Tablette · alle 8h · 7 Tage'), findsOneWidget);
      expect(find.textContaining('tablets'), findsNothing);
    });

    testWidgets('a dose inside the grace period is not yet counted as '
        'missing, on the card and in the shared text', (tester) async {
      // The dose at 08:00 is four hours old; with a five-hour grace period
      // the app does not call it missed yet, so neither does the count.
      SharedPreferences.setMockInitialValues({'missed_grace_minutes': 300});
      final shared = captureShares(tester);
      await seedAndPump(tester, beforePump: seedScheduled);
      expect(find.text('5 of 6 taken'), findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text('Share record'));
      await tester.pumpAndSettle();
      expect(shared.single, contains('\n  5 of 6 taken'));
    });

    testWidgets('while the doses load, the card claims nothing', (
      tester,
    ) async {
      final never = Completer<Result<List<DoseLog>>>();
      await seedAndPump(
        tester,
        beforePump: () => seedAsNeeded(taken: false),
        extraOverrides: [
          doseLogRepositoryProvider.overrideWithValue(
            _TreatmentDosesRepo(realDoseRepo(), (_) => never.future),
          ),
        ],
      );
      expect(find.text('Tachipirina'), findsOneWidget);
      expect(find.text('Not taken'), findsNothing);
      expect(find.byKey(const Key('intake_p2')), findsNothing);
    });

    testWidgets('a count shown before a failed re-read is taken back', (
      tester,
    ) async {
      var fail = false;
      await seedAndPump(
        tester,
        beforePump: seedScheduled,
        extraOverrides: [
          doseLogRepositoryProvider.overrideWithValue(
            _TreatmentDosesRepo(
              realDoseRepo(),
              (id) async => fail
                  ? const Result.failure('db down')
                  : realDoseRepo().getDoseLogsByTreatment(id),
            ),
          ),
        ],
      );
      expect(find.text('5 of 7 taken'), findsOneWidget);

      fail = true;
      ProviderScope.containerOf(
        tester.element(find.byType(TreatmentDetailScreen)),
      ).invalidate(doseLogsByTreatmentProvider('t1'));
      // Past the app's one automatic retry, which fails too.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('intake_p1')), findsNothing);
    });

    testWidgets('when the doses cannot be read, the card claims nothing and '
        'sharing says it failed', (tester) async {
      final shared = captureShares(tester);
      await seedAndPump(
        tester,
        beforePump: () async {
          await seedScheduled();
          await seedAsNeeded(taken: false);
        },
        extraOverrides: [
          doseLogRepositoryProvider.overrideWithValue(
            _TreatmentDosesRepo(
              realDoseRepo(),
              (_) async => const Result.failure('db down'),
            ),
          ),
        ],
      );
      expect(find.text('Tachipirina'), findsOneWidget);
      expect(find.text('Not taken'), findsNothing);
      expect(find.byKey(const Key('intake_p1')), findsNothing);
      expect(find.byKey(const Key('intake_p2')), findsNothing);

      await openMenu(tester);
      await tester.tap(find.text('Share record'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(shared, isEmpty);
      expect(find.text('Something went wrong'), findsOneWidget);
    });

    testWidgets('without a share sheet there is no "Share record"', (
      tester,
    ) async {
      await seedAndPump(tester, caps: PlatformCapabilities.web);
      await openMenu(tester);
      expect(find.text('Share record'), findsNothing);
      expect(find.text('End Treatment'), findsOneWidget);
    });

    group('layout at 360 dp', () {
      setUpAll(loadAppFonts);

      for (final locale in const ['de', 'it', 'en']) {
        testWidgets('the counts and the menu stay whole in $locale at 1.6x', (
          tester,
        ) async {
          usePhone(tester);
          useAppTextScale(tester, 1.6);
          await seedAndPump(
            tester,
            beforePump: () async {
              await seedScheduled();
              await seedAsNeeded();
            },
            locale: Locale(locale),
            scale: 1.6,
          );
          final l10n = lookupAppLocalizations(Locale(locale));
          final labels = EpisodeLabels.fromL10n(l10n);
          final scheduled = find.text(l10n.dosesTakenOfPlanned(5, 7));
          final asNeeded = find.byKey(const Key('intake_p2'));

          void expectWhole(Finder text, Rect box) {
            expect(text, findsOneWidget);
            expect(MediaQuery.textScalerOf(tester.element(text)).scale(1), 1.6);
            final data = tester.widget<Text>(text).data;
            final fit = measureText(tester, text);
            expect(
              fit.minIntrinsic,
              lessThanOrEqualTo(fit.maxWidth + 0.5),
              reason: '"$data" is broken mid-word: $fit',
            );
            expect(fit.exceeded, isFalse, reason: '"$data" is cut: $fit');
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)),
            );
            expect(
              paragraph.softWrap || fit.maxIntrinsic <= fit.maxWidth + 0.5,
              isTrue,
              reason: '"$data" does not wrap and is cut: $fit',
            );
            // A paragraph as wide as its box ends exactly on the box's
            // edge, which Rect.contains does not count as inside.
            final rect = tester.getRect(text);
            final inside = box.inflate(0.5);
            expect(
              inside.contains(rect.topLeft) &&
                  inside.contains(rect.bottomRight),
              isTrue,
              reason: '"$data" at $rect lies outside $box',
            );
          }

          Rect cardOf(Finder text) => tester.getRect(
            find.ancestor(of: text, matching: find.byType(Card)).first,
          );

          for (final text in [scheduled, asNeeded]) {
            await tester.scrollUntilVisible(text, 100);
            await tester.pumpAndSettle();
            expectWhole(text, cardOf(text));
          }
          // The as-needed line takes two lines at this scale; the break
          // falls between the dates, never inside one.
          final asNeededText = tester.widget<Text>(asNeeded).data!;
          final asNeededParagraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: asNeeded, matching: find.byType(RichText)),
          );
          expect(
            asNeededText.replaceAll('\u00A0', ' '),
            '${l10n.dosesTakenAsNeeded(3)} '
            '(${labels.date(DateTime(2026, 3, 3))} – '
            '${labels.date(DateTime(2026, 3, 4))})',
          );
          for (final day in [DateTime(2026, 3, 3), DateTime(2026, 3, 4)]) {
            final date = labels.date(day).replaceAll(' ', '\u00A0');
            final start = asNeededText.indexOf(date);
            expect(start, isNonNegative, reason: '$date in "$asNeededText"');
            final tops = asNeededParagraph
                .getBoxesForSelection(
                  TextSelection(
                    baseOffset: start,
                    extentOffset: start + date.length,
                  ),
                )
                .map((b) => b.top)
                .toSet();
            expect(tops, hasLength(1), reason: '"$date" is split: $tops');
          }
          // Nor does a line start with the dash between them.
          final dash = asNeededText.indexOf('–');
          final dashTops = asNeededParagraph
              .getBoxesForSelection(
                TextSelection(baseOffset: dash - 2, extentOffset: dash + 1),
              )
              .map((b) => b.top)
              .toSet();
          expect(
            dashTops,
            hasLength(1),
            reason: 'a line starts with the dash: "$asNeededText"',
          );
          // "14 of 15 taken" is one short fact; it keeps to one line, in
          // the same style and box as the count on screen.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: scheduled, matching: find.byType(RichText)),
          );
          final painter = TextPainter(
            text: TextSpan(
              text: l10n.dosesTakenOfPlanned(14, 15),
              style: paragraph.text.style,
            ),
            textDirection: paragraph.textDirection,
            textScaler: paragraph.textScaler,
          )..layout();
          addTearDown(painter.dispose);
          expect(
            painter.maxIntrinsicWidth,
            lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
            reason: 'a two-digit count wraps',
          );
          expect(tester.takeException(), isNull);

          await openMenu(tester);
          final screen = tester.getRect(find.byType(Scaffold).first);
          for (final label in [
            l10n.shareEpisode,
            l10n.endTreatment,
            l10n.deleteTreatment,
          ]) {
            final text = find.text(label).last;
            expectWhole(text, screen);
            // A menu entry wrapped onto two lines is still whole, but the
            // share entry must at least keep to the menu's width.
            final item = tester.getRect(
              find.ancestor(of: text, matching: find.byType(ListTile)).first,
            );
            expectWhole(text, item);
          }
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}

/// A treatment repository whose End always fails, as a full disk would.
class _EndFails extends TreatmentRepositoryImpl {
  _EndFails({required super.localDatasource});

  @override
  Future<Result<Treatment>> endTreatment(
    String id, {
    bool endSickLeave = false,
  }) async => const Result.failure('disk full');
}
