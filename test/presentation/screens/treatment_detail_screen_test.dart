/// The Krankenstand block on the treatment detail screen, and ending the
/// treatment with its sick leave.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

void main() {
  final now = DateTime(2026, 3, 5, 12);

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

  Future<void> seedAndPump(
    WidgetTester tester, {
    DateTime? from,
    DateTime? to,
    String? ref,
    String? doctor,
    Locale locale = const Locale('en'),
    double scale = 1.0,
    Future<void> Function()? beforePump,
  }) async {
    await TreatmentLocalDatasource().upsert(
      TreatmentModel(
        id: 't1',
        name: 'Sinusitis',
        startDate: DateTime(2026, 3, 3),
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
      overrides: await overrides(),
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
            'End "Sinusitis"? This will deactivate all prescriptions.',
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
        'minimum_stock_level': 0,
        'created_at': '2026-03-01T08:00:00.000',
        'updated_at': '2026-03-01T08:00:00.000',
        'sync_status': 'synced',
      });
      await db.insert('prescriptions', {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1 tablet',
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

    testWidgets('German reads "Bei Bedarf" and "Dosis eintragen"', (
      tester,
    ) async {
      await seedAndPump(
        tester,
        beforePump: seedPrescription,
        locale: const Locale('de'),
      );
      expect(find.text('1 tablet · Bei Bedarf'), findsOneWidget);
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

          expectWhole(find.text('1 tablet · ${l10n.scheduleAsNeeded}'), card);
          expectWhole(
            find.descendant(
              of: logButton,
              matching: find.text(l10n.logDoseNow),
            ),
            card,
          );

          await tester.tap(logButton);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final snack = find.text(l10n.doseLogged);
          expect(snack, findsOneWidget);
          expectWhole(snack, screen);
          expect(tester.takeException(), isNull);
        });
      }
    });
  });
}
