/// The dashboard's three stat tiles each hold a single label under a number.
/// "Behandlungen" and "Trattamenti" are one long word with no break
/// opportunity, so they cannot wrap: without an explicit overflow they are
/// painted straight past the tile and clipped, and nothing throws.
///
/// These tests therefore assert geometry, never `takeException`. Real fonts
/// are mandatory: in the test font a 12 sp label is about three times as
/// wide as on a device (see test/helpers/fonts.dart), and `loadAppFonts()`
/// is only wired up automatically under test/goldens/.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
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

  /// What the label needs, measured from the span the paragraph actually
  /// painted (resolved style, ambient text scale), against what it got.
  ///
  /// [widestWord] is the decisive number. It is the width of the longest run
  /// with no break opportunity, i.e. the width below which some word *must*
  /// be clipped or ellipsized however many lines it is given. [natural] is
  /// the one-line width, reported for context: a label wider than its box
  /// but made of several words simply wraps, which is not this bug.
  ({double natural, double widestWord, double box}) measure(
    WidgetTester tester,
    Finder label,
  ) {
    final paragraph = tester.renderObject<RenderParagraph>(label);
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
    )..layout();
    return (
      natural: painter.width,
      widestWord: painter.minIntrinsicWidth,
      box: paragraph.constraints.maxWidth,
    );
  }

  /// The stat labels live inside the tiles' [InkWell]s; some of them ("In
  /// scadenza") are also section headers further down the page, so every
  /// lookup is scoped to the tile row.
  Finder statLabel(String label) => find
      .descendant(of: find.byType(InkWell), matching: find.text(label))
      .first;

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  const labels = <String, List<String>>{
    'en': ['Expiring', 'Low stock', 'Treatments'],
    'de': ['Läuft ab', 'Wenig Vorrat', 'Behandlungen'],
    'it': ['In scadenza', 'Scorte basse', 'Trattamenti'],
  };

  for (final entry in labels.entries) {
    testWidgets('stat tile labels fit a 360 dp phone in ${entry.key}', (
      tester,
    ) async {
      usePhone(tester);

      await pumpMedoraApp(
        tester,
        const HomeScreen(),
        overrides: await overrides(),
        locale: Locale(entry.key),
      );
      await tester.pumpAndSettle();

      // Measure all three before asserting any, so a failure report carries
      // the whole row's numbers rather than only the first one to break.
      final measured =
          <String, ({double natural, double widestWord, double box})>{};
      for (final label in entry.value) {
        final finder = statLabel(label);
        expect(finder, findsOneWidget, reason: 'missing stat label $label');
        measured[label] = measure(tester, finder);
      }
      printOnFailure(
        measured.entries
            .map(
              (m) =>
                  '"${m.key}": widest word ${m.value.widestWord.toStringAsFixed(1)} dp, '
                  'one line ${m.value.natural.toStringAsFixed(1)} dp, '
                  'box ${m.value.box.toStringAsFixed(1)} dp',
            )
            .join('\n'),
      );

      for (final label in entry.value) {
        final m = measured[label]!;
        expect(
          m.widestWord,
          lessThanOrEqualTo(m.box + 0.5),
          reason:
              '"$label" contains a word wider than the ${m.box.toStringAsFixed(1)} dp '
              'the tile gives it at 360 dp, so it is clipped or ellipsized '
              'mid-word',
        );
        // Only meaningful alongside the width check: a single unbreakable
        // word is ellipsized on line 1, so this stays false even when the
        // label does not fit.
        expect(
          tester
              .renderObject<RenderParagraph>(statLabel(label))
              .didExceedMaxLines,
          isFalse,
          reason: '"$label" spilled past its line budget at 360 dp',
        );
      }
    });
  }

  for (final scale in const [1.5, 2.0]) {
    testWidgets('stat tile labels give way at a ${scale}x text scale', (
      tester,
    ) async {
      usePhone(tester);

      await pumpMedoraApp(
        tester,
        Builder(
          // Copy the ambient MediaQuery rather than replacing it, so only
          // the text scale changes and the viewport metrics survive.
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: const HomeScreen(),
          ),
        ),
        overrides: await overrides(),
        locale: const Locale('de'),
      );
      await tester.pumpAndSettle();

      // At this size the longest label cannot fit, and that is fine: it must
      // ellipsize inside its box rather than paint past it or overflow.
      final paragraph = tester.renderObject<RenderParagraph>(
        statLabel('Behandlungen'),
      );
      expect(
        paragraph.size.width,
        lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
        reason: 'the label painted outside its tile at ${scale}x',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
