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
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 12);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  /// Pumps the form under a real router, pushed on top of a stub page, so
  /// the screen's `context.pop()` after a save is a real pop.
  Future<void> pump(WidgetTester tester, {String? treatmentId}) async {
    tester.view.physicalSize = const Size(800, 2400);
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
          builder: (_, _) => AddTreatmentScreen(treatmentId: treatmentId),
        ),
      ],
    );
    addTearDown(router.dispose);
    final previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en';
    addTearDown(() => Intl.defaultLocale = previousLocale);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: const Locale('en'),
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

  Future<void> save(WidgetTester tester, {String label = 'Create Treatment'}) =>
      tester.tap(find.text(label)).then((_) => tester.pumpAndSettle());

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
    expect(
      find.text('Pick a start date on or before the end date'),
      findsOneWidget,
    );
    expect(await TreatmentLocalDatasource().getTreatments(), isEmpty);
    expect(find.text('stub home'), findsNothing);
  });

  testWidgets('an end date before the start date is rejected', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Grippe');
    await openSection(tester);

    // "To" first, then a later "from": the "to" picker's firstDate cannot
    // stop this order, so the save guard has to.
    await pickDate(tester, const Key('sickLeaveToField'), day: 4);
    await pickDate(tester, const Key('sickLeaveFromField'), day: 6);
    await save(tester);

    expect(
      find.text('Pick a start date on or before the end date'),
      findsOneWidget,
    );
    expect(await TreatmentLocalDatasource().getTreatments(), isEmpty);

    // Changing a date clears the error.
    await pickDate(tester, const Key('sickLeaveToField'), day: 8);
    expect(
      find.text('Pick a start date on or before the end date'),
      findsNothing,
    );
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
    Future<void> seed({DateTime? from, DateTime? to, String? doctor}) =>
        TreatmentLocalDatasource().upsert(
          TreatmentModel(
            id: 't1',
            name: 'Sinusitis',
            startDate: DateTime(2026, 3, 3),
            sickLeaveFrom: from,
            sickLeaveTo: to,
            sickLeaveRef: from == null ? null : '1234567890',
            doctor: doctor,
          ),
          syncStatus: 'synced',
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

      // Clear "to" first: clearing "from" first would leave an end without
      // a start, which the guard rejects.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('sickLeaveToField')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('sickLeaveFromField')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sickLeaveRefField')), '');
      await tester.enterText(find.byKey(const Key('doctorField')), '  ');
      await save(tester, label: 'Update Treatment');

      final stored = await TreatmentLocalDatasource().getTreatmentById('t1');
      expect(stored!.sickLeaveFrom, isNull);
      expect(stored.sickLeaveTo, isNull);
      expect(stored.sickLeaveRef, isNull);
      expect(stored.doctor, isNull);
    });
  });
}
