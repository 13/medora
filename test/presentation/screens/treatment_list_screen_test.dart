/// The sick-leave badge on the treatment list, and the doctor search.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/treatment_list_screen.dart';
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

  Future<void> seed(
    String id,
    String name, {
    DateTime? from,
    DateTime? to,
    String? doctor,
    List<String> patientTags = const [],
    List<String> symptomTags = const [],
  }) => TreatmentLocalDatasource().upsert(
    TreatmentModel(
      id: id,
      name: name,
      startDate: DateTime(2026, 3, 3),
      sickLeaveFrom: from,
      sickLeaveTo: to,
      doctor: doctor,
      patientTags: patientTags,
      symptomTags: symptomTags,
    ),
    syncStatus: 'synced',
  );

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    Widget Function(Widget child)? wrap,
  }) async {
    const screen = TreatmentListScreen();
    await pumpMedoraApp(
      tester,
      wrap == null ? screen : wrap(screen),
      overrides: await overrides(),
      locale: locale,
    );
    await tester.pumpAndSettle();
  }

  Finder badgeOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
    matching: find.byKey(const Key('sickLeaveBadge')),
  );

  String badgeText(WidgetTester tester, String name) => tester
      .widget<Text>(
        find.descendant(of: badgeOf(name), matching: find.byType(Text)),
      )
      .data!;

  testWidgets('an open leave reads "Sick leave · Day 3"', (tester) async {
    await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
    await pump(tester);
    expect(badgeText(tester, 'Sinusitis'), 'Sick leave · Day 3');
  });

  testWidgets('a closed leave reads "Sick leave · 7 days"', (tester) async {
    await seed(
      't1',
      'Sinusitis',
      from: DateTime(2026, 3, 3),
      to: DateTime(2026, 3, 9),
    );
    await pump(tester);
    expect(badgeText(tester, 'Sinusitis'), 'Sick leave · 7 days');
  });

  testWidgets('a leave with no valid count reads "Sick leave" alone', (
    tester,
  ) async {
    // Not started yet, and ending before it starts: both have a recorded
    // leave but no day count.
    await seed('t1', 'Future', from: DateTime(2026, 3, 10));
    await seed(
      't2',
      'Inverted',
      from: DateTime(2026, 3, 9),
      to: DateTime(2026, 3, 3),
    );
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(badgeText(tester, 'Future'), 'Sick leave');
    expect(badgeText(tester, 'Inverted'), 'Sick leave');
  });

  testWidgets('a treatment without sick leave has no badge', (tester) async {
    await seed('t1', 'Influenza', doctor: 'Dr. Rossi');
    await pump(tester);
    expect(find.text('Influenza'), findsOneWidget);
    expect(find.byKey(const Key('sickLeaveBadge')), findsNothing);
  });

  testWidgets('German reads "Krankenstand · Tag 3"', (tester) async {
    await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
    await pump(tester, locale: const Locale('de'));
    expect(badgeText(tester, 'Sinusitis'), 'Krankenstand · Tag 3');
  });

  testWidgets('searching finds a treatment by its doctor', (tester) async {
    await seed('t1', 'Sinusitis', doctor: 'Dr. Rossi, Bozen');
    await seed('t2', 'Influenza', doctor: 'Dr. Bianchi');
    await pump(tester);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'rossi');
    await tester.pumpAndSettle();

    expect(find.text('Sinusitis'), findsOneWidget);
    expect(find.text('Influenza'), findsNothing);
  });

  group('the End slide action', () {
    Future<void> slideAndTapEnd(WidgetTester tester, String name) async {
      await tester.drag(find.text(name), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SlidableAction, 'End'));
      await tester.pumpAndSettle();
    }

    final dialog = find.byType(AlertDialog);
    final checkbox = find.byKey(const Key('endSickLeaveCheckbox'));

    testWidgets('asks first, then ends the treatment and its open leave', (
      tester,
    ) async {
      await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
      await pump(tester);
      await slideAndTapEnd(tester, 'Sinusitis');

      expect(dialog, findsOneWidget);
      expect(
        (await TreatmentLocalDatasource().getTreatmentById('t1'))!.isActive,
        isTrue,
        reason: 'nothing may be ended before the user confirms',
      );
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

      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, 'End Treatment'),
        ),
      );
      await tester.pumpAndSettle();

      final t = (await TreatmentLocalDatasource().getTreatmentById('t1'))!;
      expect(t.isActive, isFalse);
      expect(t.sickLeaveTo, DateTime(2026, 3, 5));
      // The list refreshed: the row left the Active filter.
      expect(find.text('Sinusitis'), findsNothing);
    });

    testWidgets('cancelling leaves the treatment running', (tester) async {
      await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
      await pump(tester);
      await slideAndTapEnd(tester, 'Sinusitis');
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      final t = (await TreatmentLocalDatasource().getTreatmentById('t1'))!;
      expect(t.isActive, isTrue);
      expect(t.sickLeaveTo, isNull);
    });

    testWidgets('a treatment without a leave gets no box', (tester) async {
      await seed('t1', 'Influenza');
      await pump(tester);
      await slideAndTapEnd(tester, 'Influenza');
      expect(dialog, findsOneWidget);
      expect(checkbox, findsNothing);

      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(TextButton, 'End Treatment'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (await TreatmentLocalDatasource().getTreatmentById('t1'))!.isActive,
        isFalse,
      );
    });
  });

  group('layout at 360 dp', () {
    setUpAll(loadAppFonts);

    testWidgets('the capped prescription count is not shrunk at 1.0x', (
      tester,
    ) async {
      usePhone(tester);
      await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
      await pump(tester, locale: const Locale('de'));

      // "Verschreibungen" is the widest label of the three languages.
      final label = find.text('Verschreibungen');
      final fit = measureText(tester, label);
      // getRect, not getSize: only the rect includes FittedBox's scale.
      final painted = tester.getRect(label).width;
      printOnFailure('painted $painted; $fit');
      expect(
        painted,
        moreOrLessEquals(fit.maxIntrinsic, epsilon: 0.5),
        reason: 'the cap scaled the count down at an ordinary text scale',
      );
    });

    for (final locale in const ['de', 'it', 'en']) {
      testWidgets('name and badge stay whole in $locale at 1.6x', (
        tester,
      ) async {
        usePhone(tester);
        await seed(
          't1',
          'Sinusitis',
          from: DateTime(2026, 3, 3),
          patientTags: const ['Ben'],
          symptomTags: const ['Fieber', 'Kopfschmerzen'],
        );
        await seed(
          't2',
          'Bronchitis',
          from: DateTime(2026, 2, 3),
          to: DateTime(2026, 3, 4),
        );
        await pump(
          tester,
          locale: Locale(locale),
          wrap: (child) => withTextScale(1.6, child),
        );

        for (final name in const ['Sinusitis', 'Bronchitis']) {
          final title = measureText(tester, find.text(name));
          final badge = measureText(
            tester,
            find.descendant(of: badgeOf(name), matching: find.byType(Text)),
          );
          printOnFailure('$name: title $title; badge $badge');
          expect(
            title.minIntrinsic,
            lessThanOrEqualTo(title.maxWidth + 0.5),
            reason: '"$name" is broken mid-word: $title',
          );
          // The badge may wrap at a space, but never mid-word and never
          // past its line limit.
          expect(
            badge.minIntrinsic,
            lessThanOrEqualTo(badge.maxWidth + 0.5),
            reason: 'the badge of "$name" is broken mid-word: $badge',
          );
          expect(
            badge.exceeded,
            isFalse,
            reason: 'the badge of "$name" is cut off: $badge',
          );
        }
      });
    }
  });
}
