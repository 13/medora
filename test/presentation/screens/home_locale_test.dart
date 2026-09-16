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
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/local/app_database.dart';
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

      expect(tester.takeException(), isNull);
      expectNothingPaintsOutsideViewport(tester);
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

    expect(tester.takeException(), isNull);
    expectNothingPaintsOutsideViewport(tester);
  });

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
    expect(tester.takeException(), isNull);
    expectNothingPaintsOutsideViewport(tester);

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
