/// The Krankenstand (sick leave) section of Add/Edit Treatment: collapsed by
/// default, validated before anything is written, and cleared through the
/// constructor path because `copyWith` cannot null a field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/provider_retry.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

void main() {
  final now = DateTime(2026, 3, 4, 12);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  /// Pumps the form under a real router, pushed on top of a stub page, so
  /// the screen's `context.pop()` after a save is a real pop.
  Future<void> pump(
    WidgetTester tester, {
    String? treatmentId,
    Locale locale = const Locale('en'),
    double scale = 1.0,
    Size size = const Size(800, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.desktop,
        ),
        nowProvider.overrideWithValue(() => now),
      ],
      retry: medoraRetry,
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/form'),
              child: const Text('stub home'),
            ),
          ),
        ),
        GoRoute(
          path: '/form',
          builder: (_, _) => withTextScale(
            scale,
            AddTreatmentScreen(treatmentId: treatmentId),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = locale.languageCode;
    addTearDown(() => Intl.defaultLocale = previousLocale);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('stub home'));
    await tester.pumpAndSettle();
  }

  bool sectionVisible(WidgetTester tester) => tester
      .widget<Visibility>(
        find
            .descendant(
              of: find.byKey(const Key('sickLeaveSection')),
              matching: find.byType(Visibility),
            )
            .first,
      )
      .visible;

  Future<void> openSection(WidgetTester tester) async {
    await tester.tap(find.text('Sick leave'));
    await tester.pumpAndSettle();
  }

  /// Opens [field]'s picker, picks [day] of the month shown (or keeps the
  /// initial date when null) and confirms.
  Future<void> pickDate(WidgetTester tester, Key field, {int? day}) async {
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    if (day != null) {
      await tester.tap(
        find.descendant(of: find.byType(Dialog), matching: find.text('$day')),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  /// Taps the form's only ElevatedButton (Create or Update, any locale).
  Future<void> save(WidgetTester tester) async {
    final button = find.byType(ElevatedButton);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Finder clearButtonOf(Key field) => find.descendant(
    of: find.byKey(field),
    matching: find.byIcon(Icons.clear),
  );

  /// The section's error line, which has to reach a screen reader on its
  /// own: Save does nothing else a blind user could notice. (testWidgets
  /// enables semantics by default.)
  void expectAnnounced(WidgetTester tester, String message) {
    expect(find.text(message), findsOneWidget);
    expect(
      tester.getSemantics(find.text(message)),
      isSemantics(isLiveRegion: true, label: message),
    );
  }

  const fromMissing = 'Please also enter "Unable to work from"';
  const toBeforeFrom =
      '"Unable to work until" can\'t be before "Unable to work from"';

  testWidgets('the Krankenstand section is collapsed by default', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const Key('sickLeaveSection')), findsOneWidget);
    // FormSection keeps a collapsed body in the tree (maintainState) and
    // hides it, so this asserts visibility, not presence.
    expect(sectionVisible(tester), isFalse);
  });

  testWidgets('saving a sick leave writes all four columns and pops', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(
      find.byType(TextFormField).first,
      'Stirnhöhlenentzündung',
    );
    await openSection(tester);
    expect(sectionVisible(tester), isTrue);

    await pickDate(tester, const Key('sickLeaveFromField'), day: 3);
    await pickDate(tester, const Key('sickLeaveToField'), day: 9);
    await tester.enterText(
      find.byKey(const Key('sickLeaveRefField')),
      ' 1234567890 ',
    );
    await tester.enterText(
      find.byKey(const Key('doctorField')),
      'Dr. Rossi, Bozen',
    );
    await tester.pumpAndSettle();

    await save(tester);

    final stored = (await TreatmentLocalDatasource().getTreatments()).single;
    expect(stored.name, 'Stirnhöhlenentzündung');
    expect(stored.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(stored.sickLeaveTo, DateTime(2026, 3, 9));
    expect(stored.sickLeaveRef, '1234567890');
    expect(stored.doctor, 'Dr. Rossi, Bozen');
    // Popped back to the stub: the save completed, not the error path.
    expect(find.text('stub home'), findsOneWidget);
  });

  testWidgets('an ordinary therapy leaves all four columns empty', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Grippe');
    await save(tester);

    final stored = (await TreatmentLocalDatasource().getTreatments()).single;
    expect(stored.sickLeaveFrom, isNull);
    expect(stored.sickLeaveTo, isNull);
    expect(stored.sickLeaveRef, isNull);
    expect(stored.doctor, isNull);
  });

  testWidgets('the collapsed section summarises the range', (tester) async {
    await pump(tester);
    await openSection(tester);
    await pickDate(tester, const Key('sickLeaveFromField'), day: 3);
    await openSection(tester); // collapse again
    expect(sectionVisible(tester), isFalse);
    expect(find.text('Mar 3, 2026 – Ongoing'), findsOneWidget);
  });

  testWidgets('an end date without a start date is rejected', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Grippe');
    await openSection(tester);

    await pickDate(tester, const Key('sickLeaveToField'));
    // Collapse it, so the save has to force it open again.
    await openSection(tester);
    expect(sectionVisible(tester), isFalse);

    await save(tester);

    expect(sectionVisible(tester), isTrue);
    expectAnnounced(tester, fromMissing);
    expect(await TreatmentLocalDatasource().getTreatments(), isEmpty);
    expect(find.text('stub home'), findsNothing);
  });

  testWidgets('the start picker cannot go past the end date', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Grippe');
    await openSection(tester);

    // "Until" first, on a day before today: the "from" picker is bounded by
    // it, so it opens on that day instead of today and the pair stays valid.
    await pickDate(tester, const Key('sickLeaveToField'), day: 2);
    await pickDate(tester, const Key('sickLeaveFromField'));
    expect(tester.takeException(), isNull);
    await save(tester);

    expect(find.text(toBeforeFrom), findsNothing);
    final stored = (await TreatmentLocalDatasource().getTreatments()).single;
    expect(stored.sickLeaveFrom, DateTime(2026, 3, 2));
    expect(stored.sickLeaveTo, DateTime(2026, 3, 2));
  });

  testWidgets('a start date after today still opens the end-date picker', (
    tester,
  ) async {
    // The end picker's firstDate is the start date; with no end date its
    // initial date would be today, before firstDate, which showDatePicker
    // rejects with an assertion.
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'OP-Nachsorge');
    await openSection(tester);
    await pickDate(tester, const Key('sickLeaveFromField'), day: 10);
    await pickDate(tester, const Key('sickLeaveToField'));
    expect(tester.takeException(), isNull);
    await save(tester);

    final stored = (await TreatmentLocalDatasource().getTreatments()).single;
    expect(stored.sickLeaveFrom, DateTime(2026, 3, 10));
    expect(stored.sickLeaveTo, DateTime(2026, 3, 10));
  });

  group('edit mode', () {
    Future<void> seed({
      DateTime? from,
      DateTime? to,
      String? doctor,
      String? ref,
    }) => TreatmentLocalDatasource().upsert(
      TreatmentModel(
        id: 't1',
        name: 'Sinusitis',
        startDate: DateTime(2026, 3, 3),
        sickLeaveFrom: from,
        sickLeaveTo: to,
        sickLeaveRef: ref ?? (from == null ? null : '1234567890'),
        doctor: doctor,
      ),
      syncStatus: 'synced',
    );

    /// The collapsed section's summary line (the text fields are offstage
    /// while collapsed, so they do not match).
    Finder summary(String text) => find.descendant(
      of: find.byKey(const Key('sickLeaveSection')),
      matching: find.byWidgetPredicate((w) => w is Text && w.data == text),
    );

    testWidgets('opens the section and fills it when the treatment has a '
        'sick leave', (tester) async {
      await seed(
        from: DateTime(2026, 3, 3),
        to: DateTime(2026, 3, 9),
        doctor: 'Dr. Rossi',
      );
      await pump(tester, treatmentId: 't1');

      expect(sectionVisible(tester), isTrue);
      expect(find.text('Mar 3, 2026'), findsOneWidget);
      expect(find.text('Mar 9, 2026'), findsOneWidget);
      expect(find.text('1234567890'), findsOneWidget);
      expect(find.text('Dr. Rossi'), findsOneWidget);
    });

    testWidgets('opens the section for a doctor alone', (tester) async {
      await seed(doctor: 'Dr. Rossi');
      await pump(tester, treatmentId: 't1');
      expect(sectionVisible(tester), isTrue);
    });

    testWidgets('opens the section for an end date alone', (tester) async {
      await seed(to: DateTime(2026, 3, 9));
      await pump(tester, treatmentId: 't1');
      expect(sectionVisible(tester), isTrue);
    });

    testWidgets('collapsed without dates, the summary names the doctor, '
        'else the certificate', (tester) async {
      await seed(doctor: 'Dr. Rossi', ref: '9999');
      await pump(tester, treatmentId: 't1');
      await openSection(tester); // collapse
      expect(sectionVisible(tester), isFalse);
      expect(summary('Dr. Rossi'), findsOneWidget);

      await openSection(tester);
      await tester.enterText(find.byKey(const Key('doctorField')), '');
      await openSection(tester);
      expect(summary('9999'), findsOneWidget);
    });

    testWidgets('a stored leave that ends before it starts blocks the save', (
      tester,
    ) async {
      await seed(from: DateTime(2026, 3, 9), to: DateTime(2026, 3, 3));
      await pump(tester, treatmentId: 't1');
      await openSection(tester); // collapse, so the save must reopen it
      await save(tester);

      expect(sectionVisible(tester), isTrue);
      expectAnnounced(tester, toBeforeFrom);
      final stored = await TreatmentLocalDatasource().getTreatmentById('t1');
      expect(stored!.sickLeaveTo, DateTime(2026, 3, 3));
      expect(find.text('stub home'), findsNothing);

      // Changing a date clears the error.
      await pickDate(tester, const Key('sickLeaveToField'), day: 12);
      expect(find.text(toBeforeFrom), findsNothing);
      await save(tester);
      final fixed = await TreatmentLocalDatasource().getTreatmentById('t1');
      expect(fixed!.sickLeaveTo, DateTime(2026, 3, 12));
    });

    testWidgets('clearing the start date also clears the end date', (
      tester,
    ) async {
      // Without a start an end date means nothing; keeping it would block
      // the save with an error about the field the user just emptied.
      await seed(from: DateTime(2026, 3, 3), to: DateTime(2026, 3, 9));
      await pump(tester, treatmentId: 't1');

      await tester.tap(clearButtonOf(const Key('sickLeaveFromField')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('sickLeaveToField')),
          matching: find.text('Select date'),
        ),
        findsOneWidget,
      );
      expect(clearButtonOf(const Key('sickLeaveToField')), findsNothing);

      await save(tester);
      expect(find.text(fromMissing), findsNothing);
      expect(find.text('stub home'), findsOneWidget);
      final stored = await TreatmentLocalDatasource().getTreatmentById('t1');
      expect(stored!.sickLeaveFrom, isNull);
      expect(stored.sickLeaveTo, isNull);
      expect(stored.sickLeaveRef, '1234567890');
    });

    testWidgets('stays collapsed for a treatment without either', (
      tester,
    ) async {
      await seed();
      await pump(tester, treatmentId: 't1');
      expect(sectionVisible(tester), isFalse);
    });

    testWidgets('clearing the fields clears the stored columns', (
      tester,
    ) async {
      await seed(
        from: DateTime(2026, 3, 3),
        to: DateTime(2026, 3, 9),
        doctor: 'Dr. Rossi',
      );
      await pump(tester, treatmentId: 't1');

      await tester.tap(clearButtonOf(const Key('sickLeaveToField')));
      await tester.pumpAndSettle();
      await tester.tap(clearButtonOf(const Key('sickLeaveFromField')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sickLeaveRefField')), '');
      await tester.enterText(find.byKey(const Key('doctorField')), '  ');
      await save(tester);

      final stored = await TreatmentLocalDatasource().getTreatmentById('t1');
      expect(stored!.sickLeaveFrom, isNull);
      expect(stored.sickLeaveTo, isNull);
      expect(stored.sickLeaveRef, isNull);
      expect(stored.doctor, isNull);
    });
  });

  group('error wording and layout at 360 dp', () {
    setUpAll(loadAppFonts);

    // Each message names the sick-leave fields as the form labels them, not
    // the treatment's own start and end dates.
    const messages = {
      'de': (
        missing: 'Bitte auch "Arbeitsunfähig von" angeben',
        order:
            '"Arbeitsunfähig bis" darf nicht vor "Arbeitsunfähig von" liegen',
      ),
      'it': (
        missing: 'Indica anche "In malattia dal"',
        order: '"In malattia fino al" non può precedere "In malattia dal"',
      ),
      'en': (missing: fromMissing, order: toBeforeFrom),
    };

    Future<void> seedRow({DateTime? from, required DateTime to}) =>
        TreatmentLocalDatasource().upsert(
          TreatmentModel(
            id: 't1',
            name: 'Sinusitis',
            startDate: DateTime(2026, 3, 3),
            sickLeaveFrom: from,
            sickLeaveTo: to,
          ),
          syncStatus: 'synced',
        );

    Future<void> expectWhole(WidgetTester tester, String message) async {
      expect(find.text(message), findsOneWidget);
      await tester.ensureVisible(find.text(message));
      final fit = measureText(tester, find.text(message));
      printOnFailure('"$message": $fit');
      expect(
        fit.minIntrinsic,
        lessThanOrEqualTo(fit.maxWidth + 0.5),
        reason: '"$message" is broken mid-word: $fit',
      );
      expect(fit.exceeded, isFalse, reason: '"$message" is cut: $fit');
      expect(tester.takeException(), isNull);
    }

    for (final MapEntry(key: locale, value: text) in messages.entries) {
      testWidgets('an end date without a start reads right in $locale at '
          '1.6x', (tester) async {
        await seedRow(to: DateTime(2026, 3, 9));
        await pump(
          tester,
          treatmentId: 't1',
          locale: Locale(locale),
          scale: 1.6,
          size: const Size(360, 2400),
        );
        await save(tester);
        await expectWhole(tester, text.missing);
      });

      testWidgets('an end before the start reads right in $locale at 1.6x', (
        tester,
      ) async {
        await seedRow(from: DateTime(2026, 3, 9), to: DateTime(2026, 3, 3));
        await pump(
          tester,
          treatmentId: 't1',
          locale: Locale(locale),
          scale: 1.6,
          size: const Size(360, 2400),
        );
        await save(tester);
        await expectWhole(tester, text.order);
      });
    }
  });
}
