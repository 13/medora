/// The dashboard outside its comfortable case: German and Italian, a 360 dp
/// phone, a large text scale, and dark. Every other Home test is English at
/// a wide viewport in light, and dark was covered only by a golden PNG.
///
/// Real fonts are mandatory here: `flutter_test` renders every glyph as a
/// 1-em box unless they are registered, which makes a 12 sp label about three
/// times as wide as on a device (see test/helpers/fonts.dart), and
/// `loadAppFonts()` is only wired up automatically under test/goldens/. A
/// width assertion measured in the test font would fail for a reason that
/// does not exist on a phone.
///
/// Stat-tile widths belong to home_stat_tile_layout_test.dart and are not
/// re-asserted here; this file is about the cards and the page as a whole.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/contrast.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUpAll(loadAppFonts);

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

  /// One expired medication, one low-stock medication that is also expiring,
  /// one active treatment and a dose today: every card populated, which is
  /// the case a narrow viewport and a large text scale have to survive.
  Future<void> seedFullDashboard() async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    // getTodaysDoseLogs keys off the real wall clock by design, not
    // nowProvider, so the dose seeds are placed relative to the real now.
    final real = DateTime.now();
    await seedDoseLog(
      db,
      seeded.prescriptionId,
      recentToday(real),
      status: 'taken',
    );
    await seedDoseLog(db, seeded.prescriptionId, laterToday(real));
    await db.insert('medications', {
      'id': 'exp',
      'name': 'Bentelan',
      'quantity': 8,
      'expiry_date': '2025-12-01',
    });
    await db.insert('medications', {
      'id': 'low',
      'name': 'Moment 200',
      'quantity': 0,
      'minimum_stock_level': 0,
      'expiry_date': '2026-03-20',
    });
  }

  const width = 360.0;

  void useNarrowPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Every piece of text the dashboard has laid out, measured against the
  /// viewport it was given.
  ///
  /// A `RenderFlex overflowed` does surface as an exception, but the two
  /// failures this file is actually about do not: `TextOverflow.clip` paints
  /// a label past its line box in silence, and a `Text` inside an unbounded
  /// parent simply takes the width it wants. Geometry is the assertion that
  /// bites. Rects are read through `localToGlobal`, so a shrink-to-fit
  /// transform is already applied and a scaled-down label is not a false
  /// positive.
  void expectNothingPaintsOutsideViewport(WidgetTester tester) {
    final offenders = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.isEmpty) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      final right = box.localToGlobal(box.size.bottomRight(Offset.zero)).dx;
      if (left < -0.5 || right > width + 0.5) {
        final text = (element.widget as Text).data ?? '<rich>';
        offenders.add(
          '"$text" spans ${left.toStringAsFixed(1)}..'
          '${right.toStringAsFixed(1)} dp',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these labels paint outside the ${width.toStringAsFixed(0)} dp '
          'viewport:\n${offenders.join('\n')}',
    );
  }

  /// The first [RenderParagraph] under [element], which is where a `Text`
  /// finally lays its glyphs out. A semantics label or a selection registrar
  /// puts another render object in between, so walk down rather than assume
  /// the paragraph is the element's own render object.
  RenderParagraph? paragraphOf(Element element) {
    RenderParagraph? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderParagraph) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    final root = element.renderObject;
    if (root != null) visit(root);
    return found;
  }

  /// Every label measured against the box it was actually given.
  ///
  /// A paragraph handed too little width does not report a bigger size: it
  /// breaks mid-word, ellipsizes, or - the default - clips in silence. Both
  /// `takeException` and the render-box sweep above therefore stay happy
  /// while the user reads "Moment 2". The number that decides it is the
  /// widest run of text that cannot be broken - the longest word, at this
  /// paragraph's own text scale, which is what `TextPainter.minIntrinsicWidth`
  /// reports. If that does not fit `constraints.maxWidth`, something on
  /// screen has been truncated. This is the comparison
  /// home_stat_tile_layout_test.dart makes for the three stat tiles; here it
  /// runs over every label the dashboard painted.
  ///
  /// [knownTruncations] names labels a production layout already truncates
  /// at this configuration, mapped to why. They do not fail the sweep - this
  /// file may not change the widgets involved - but they are not ignored
  /// either: every entry must still be truncating, so an entry that gets
  /// fixed, or designed away, turns this red and has to go.
  void expectNoTextIsClipped(
    WidgetTester tester, {
    Map<String, String> knownTruncations = const {},
  }) {
    final offenders = <String>[];
    final clipped = <String>{};
    for (final element in find.byType(Text).evaluate()) {
      final paragraph = paragraphOf(element);
      if (paragraph == null || !paragraph.attached || !paragraph.hasSize) {
        continue;
      }
      // An unbounded parent - the shrink-to-fit trailing column, a
      // horizontal scroll axis - has no box for the text to exceed.
      final box = paragraph.constraints.maxWidth;
      if (!box.isFinite) continue;
      // A WidgetSpan has no intrinsic width of its own, and laying one out
      // without placeholder dimensions throws rather than measures.
      var hasPlaceholder = false;
      paragraph.text.visitChildren((span) {
        if (span is PlaceholderSpan) hasPlaceholder = true;
        return !hasPlaceholder;
      });
      if (hasPlaceholder) continue;

      final painter = TextPainter(
        text: paragraph.text,
        textDirection: paragraph.textDirection,
        textScaler: paragraph.textScaler,
        strutStyle: paragraph.strutStyle,
        textAlign: paragraph.textAlign,
        locale: paragraph.locale,
      )..layout();
      final widestWord = painter.minIntrinsicWidth;
      painter.dispose();
      // An ellipsized or line-capped label hits its maxLines without any
      // single word being too wide, so the longest-word check alone let
      // three of the four cut section headings pass in silence.
      if (paragraph.didExceedMaxLines) {
        final label = paragraph.text.toPlainText();
        clipped.add(label);
        if (knownTruncations.containsKey(label)) continue;
        offenders.add(
          '"$label" hit its line limit in ${box.toStringAsFixed(1)} dp and '
          'was cut',
        );
      } else if (widestWord > box + 0.5) {
        final label = paragraph.text.toPlainText();
        clipped.add(label);
        if (knownTruncations.containsKey(label)) continue;
        offenders.add(
          '"$label" needs ${widestWord.toStringAsFixed(1)} dp for its longest '
          'unbreakable run but was given ${box.toStringAsFixed(1)} dp '
          '(it painted ${paragraph.size.width.toStringAsFixed(1)} dp wide)',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these labels do not fit the box they were given, so they are '
          'clipped, ellipsized or broken mid-word:\n${offenders.join('\n')}',
    );
    final repaired = knownTruncations.keys.where((l) => !clipped.contains(l));
    expect(
      repaired,
      isEmpty,
      reason:
          'these labels are listed as known truncations but now fit their '
          'box: ${repaired.join(', ')}. Delete them from knownTruncations so '
          'the sweep guards them again.',
    );
  }

  const expiredLabel = {'de': 'Abgelaufen', 'it': 'Scaduto'};
  const wellStocked = {
    'de': 'Alle Medikamente sind vorrätig',
    'it': 'Tutti i farmaci sono ben forniti',
  };
  const withinDate = {
    'de': 'Alle Medikamente sind haltbar',
    'it': 'Tutti i farmaci sono in corso di validità',
  };
  const sectionHeader = {
    'de': 'Abgelaufen & bald ablaufend',
    'it': 'Scaduti e in scadenza',
  };

  const takeAction = {'de': 'Einnehmen', 'it': 'Assumi', 'en': 'Take'};
  const skipAction = {'de': 'Überspringen', 'it': 'Salta', 'en': 'Skip'};
  const leftLabel = {'de': 'Übrig', 'it': 'Rimanenti', 'en': 'Left'};

  /// The two widgets commit 4e405da rebuilt, pinned to the screen.
  ///
  /// Neither overflow can reach `takeException` unless the offending widget
  /// is actually built, and both are conditional: the Now card renders its
  /// "all done" branch instead of the action pair when no dose is pending,
  /// and the dose seeds key off the real wall clock (see seedFullDashboard).
  /// Without these assertions a run crossing midnight, or any change to dose
  /// generation, would leave all four tests green with nothing under test.
  void expectTheOverflowingWidgetsAreOnScreen(String lang) {
    expect(
      find.text(takeAction[lang]!),
      findsOneWidget,
      reason:
          'the Now card is not offering a next dose, so the action row that '
          'overflowed by 2.3 dp at 1.0x and 83 dp at 1.6x is not on screen '
          'to be measured',
    );
    expect(find.text(skipAction[lang]!), findsOneWidget);

    final left = find.text(leftLabel[lang]!);
    expect(
      left,
      findsOneWidget,
      reason:
          'the Low Stock row is not showing its trailing count column, so '
          'the column that overflowed by 12 dp is not on screen',
    );
    // "Moment 200" is seeded at zero, and the count sits directly above the
    // label in the trailing column.
    expect(
      find.descendant(
        of: find.ancestor(of: left, matching: find.byType(Column)).first,
        matching: find.text('0'),
      ),
      findsOneWidget,
      reason: 'the trailing column has lost the quantity above "$left"',
    );
  }

  for (final lang in const ['de', 'it']) {
    testWidgets('the full dashboard lays out at 360 dp in $lang', (
      tester,
    ) async {
      useNarrowPhone(tester);
      await seedFullDashboard();

      await pumpMedoraApp(
        tester,
        const HomeScreen(),
        overrides: await overrides(),
        locale: Locale(lang),
      );
      await tester.pumpAndSettle();

      // The translated section header and the translated expiry badge are
      // both on screen, so the expired row survives this locale's longer
      // strings at this width.
      expect(find.text(sectionHeader[lang]!), findsOneWidget);
      expect(find.text(expiredLabel[lang]!), findsOneWidget);
      expect(find.text('Bentelan'), findsOneWidget);

      // Moment 200 is low on stock *and* expiring, so it heads both cards.
      expect(find.text('Moment 200'), findsNWidgets(2));

      // Neither "all is well" empty state may claim otherwise.
      expect(find.text(wellStocked[lang]!), findsNothing);
      expect(find.text(withinDate[lang]!), findsNothing);

      // The treatment card and the progress line are populated too.
      expect(find.text('Flu'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      expectTheOverflowingWidgetsAreOnScreen(lang);

      expect(tester.takeException(), isNull);
      expectNothingPaintsOutsideViewport(tester);
      expectNoTextIsClipped(tester);
    });
  }

  testWidgets('the dashboard survives a 1.6x text scale at 360 dp', (
    tester,
  ) async {
    useNarrowPhone(tester);
    await seedFullDashboard();

    await pumpMedoraApp(
      tester,
      Builder(
        // Copy the ambient MediaQuery rather than replacing it: a bare
        // `MediaQueryData` would also zero the viewport size and padding,
        // and the test would then be measuring a different page.
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: const HomeScreen(),
        ),
      ),
      overrides: await overrides(),
      locale: const Locale('de'),
    );
    await tester.pumpAndSettle();

    // German is the widest of the three locales, and 1.6x is past the top of
    // Android's font-size slider.
    expect(find.text('Abgelaufen'), findsOneWidget);
    expect(find.text('Bentelan'), findsOneWidget);
    expect(find.text('Flu'), findsOneWidget);

    expectTheOverflowingWidgetsAreOnScreen('de');

    expect(tester.takeException(), isNull);
    expectNothingPaintsOutsideViewport(tester);
    // Nothing is truncated at this scale. "Aktive Behandlungen" used to be
    // cut inside "Behandlungen" (163.6 dp for 180.6) by a section header
    // that ellipsized its title; the header now wraps instead.
    expectNoTextIsClipped(tester);
  });

  for (final (lang, twoMore, oneMore) in const [
    ('de', '2 weitere', '1 weiteres'),
    ('it', 'Altri 2', '1 altro'),
  ]) {
    testWidgets('the three "more" rows fit at 360 dp and 1.6x in $lang', (
      tester,
    ) async {
      useNarrowPhone(tester);
      final db = await AppDatabase.instance.database;
      // Five medications that are both low on stock and expiring, and four
      // active treatments: every card that caps at three rows shows its
      // "more" row.
      for (var i = 1; i <= 5; i++) {
        await db.insert('medications', {
          'id': 'm$i',
          'name': 'Moment 20$i',
          'quantity': 0,
          'minimum_stock_level': 0,
          'expiry_date': '2026-03-2$i',
        });
      }
      for (var i = 1; i <= 4; i++) {
        await db.insert('treatments', {
          'id': 't$i',
          'name': 'Episode $i',
          'start_date': '2026-03-0$i',
          'is_active': 1,
        });
      }

      await pumpMedoraApp(
        tester,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: const HomeScreen(),
          ),
        ),
        overrides: await overrides(),
        locale: Locale(lang),
      );
      await tester.pumpAndSettle();

      final rows = find.byKey(const Key('dashboardMoreRow'));
      expect(rows, findsNWidgets(3));
      // Expiring and low stock hide two each, treatments hide one.
      expect(
        find.descendant(of: rows, matching: find.text(twoMore)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: rows, matching: find.text(oneMore)),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
      expectNothingPaintsOutsideViewport(tester);
      expectNoTextIsClipped(tester);
    });
  }

  // The four section headings at large text: whole, on at most two lines,
  // and each with its "See all" on screen and tappable.
  for (final lang in const ['de', 'it', 'en']) {
    for (final scale in const [1.0, 1.3, 1.6, 2.0]) {
      testWidgets('section headings wrap instead of being cut at 360 dp, '
          '$lang, ${scale}x', (tester) async {
        useNarrowPhone(tester);
        await seedFullDashboard();
        final errors = <String>[];
        await pumpMedoraApp(
          tester,
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: const HomeScreen(),
            ),
          ),
          overrides: await overrides(),
          locale: Locale(lang),
        );
        await tester.pumpAndSettle();
        // Some card rows overflow at 2.0x (outside the headings, see the
        // design's deferred list); only the headings are this test's subject.
        while (true) {
          final e = tester.takeException();
          if (e == null) break;
          errors.add('$e');
        }
        if (scale < 2) expect(errors, isEmpty);

        final l10n = lookupAppLocalizations(Locale(lang));
        final seeAll = find.widgetWithText(TextButton, l10n.seeAll);
        expect(seeAll, findsNWidgets(3));
        for (final heading in [
          l10n.activeTreatments,
          l10n.expiringOrExpired,
          l10n.lowStock,
        ]) {
          final where = '"$heading" ($lang, ${scale}x)';
          // Scoped to the header: Italian's stat tile says "Scorte basse" too.
          final text = find.descendant(
            of: find.ancestor(
              of: seeAll.first,
              matching: find.byType(ListView),
            ),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.data == heading &&
                  w.style?.fontWeight == FontWeight.w600,
            ),
          );
          expect(text, findsOneWidget, reason: where);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: text,
              matching: find.byType(RichText),
              matchRoot: true,
            ),
          );
          final painter = TextPainter(
            text: paragraph.text,
            textDirection: paragraph.textDirection,
            textScaler: paragraph.textScaler,
            locale: paragraph.locale,
          )..layout(maxWidth: paragraph.constraints.maxWidth);
          addTearDown(painter.dispose);
          printOnFailure(
            '$where: box ${paragraph.constraints.maxWidth}, '
            'lines ${painter.computeLineMetrics().length}, '
            'longest word ${painter.minIntrinsicWidth}',
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: where);
          expect(
            painter.minIntrinsicWidth,
            lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
            reason: '$where is broken inside a word',
          );
          expect(
            painter.computeLineMetrics().length,
            lessThanOrEqualTo(2),
            reason: '$where takes more than two lines',
          );
          final box = tester.getRect(text);
          expect(box.left, greaterThanOrEqualTo(0), reason: where);
          expect(box.right, lessThanOrEqualTo(width), reason: where);
        }
        for (final e in seeAll.evaluate()) {
          final button = find.byElementPredicate((x) => x == e);
          final r = tester.getRect(button);
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(width));
          expect(r.height, greaterThanOrEqualTo(40));
          final label = measureText(
            tester,
            find.descendant(of: button, matching: find.text(l10n.seeAll)),
          );
          expect(
            label.maxIntrinsic,
            lessThanOrEqualTo(label.maxWidth + 0.5),
            reason: '"${l10n.seeAll}" is cut ($lang, ${scale}x)',
          );
        }
      });
    }
  }

  testWidgets('dark mode renders the same dashboard, legibly', (tester) async {
    useNarrowPhone(tester);
    await seedFullDashboard();

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
      brightness: Brightness.dark,
    );
    await tester.pumpAndSettle();

    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Bentelan'), findsOneWidget);
    expect(find.text('Flu'), findsOneWidget);
    expectTheOverflowingWidgetsAreOnScreen('en');

    expect(tester.takeException(), isNull);
    expectNothingPaintsOutsideViewport(tester);
    expectNoTextIsClipped(tester);

    // The expired badge has to stay readable in the dark palette, not just
    // exist. Measured off what the badge actually paints — the decoration
    // behind it and the colour of its own glyphs — so a badge that stopped
    // using the semantic pair would be caught here rather than a palette
    // check that passes whatever the widget does with it.
    final label = find.text('Expired');
    final badge = tester.widget<Container>(
      find.ancestor(of: label, matching: find.byType(Container)).first,
    );
    final background = (badge.decoration! as BoxDecoration).color!;
    final foreground = tester.widget<Text>(label).style!.color!;

    final medora = Theme.of(tester.element(label)).extension<MedoraColors>()!;
    expect(
      background,
      medora.dangerContainer,
      reason:
          'the expired badge must use the danger container, not a '
          'hardcoded red that no theme can follow',
    );
    expect(foreground, medora.onDangerContainer);

    // WCAG AA for small text is 4.5:1.
    expect(
      contrastRatio(foreground, background),
      greaterThanOrEqualTo(4.5),
      reason:
          'the dark expired badge is ${contrastRatio(foreground, background).toStringAsFixed(2)}:1',
    );
  });
}
