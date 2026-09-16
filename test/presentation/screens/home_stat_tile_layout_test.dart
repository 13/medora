/// The dashboard's three stat tiles each hold a single label under a number.
/// The German and Italian labels are one long word, and a word wider than its
/// line is broken by Skia at an arbitrary character - not clipped, and not
/// ellipsized. The bug the user reported was "Behandlun / gen", so that is
/// what these tests look for.
///
/// They assert geometry, never `takeException`, and they assert it at every
/// text scale up to 2.0x: the German label had 4.5 dp of headroom at 1.0x, so
/// the same break returned at about 1.06x - one notch of Android's font-size
/// slider. Real fonts are mandatory: in the test font a 12 sp label is about
/// three times as wide as on a device (see test/helpers/fonts.dart), and
/// `loadAppFonts()` is only wired up automatically under test/goldens/.
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

  /// What the label actually paints, against what the tile gives it.
  ///
  /// [painted] is the on-screen rect, so a shrink-to-fit transform is
  /// included. [lines] is the decisive number: one line cannot contain a
  /// mid-word break. [unscaled] is what the same label paints at a 1.0x text
  /// scale - the floor below which shrinking to fit would quietly be undoing
  /// the user's font-size setting.
  ({double painted, double box, int lines, double unscaled}) measure(
    WidgetTester tester,
    Finder label,
  ) {
    final paragraph = tester.renderObject<RenderParagraph>(label);
    final unscaled = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: TextScaler.noScaling,
    )..layout();
    // Laid out unbounded, so this is one line of the label at the ambient
    // text scale: the height the paragraph would have if it never wrapped.
    final oneLine = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
    )..layout();
    final card = find.ancestor(of: label, matching: find.byType(Card)).first;
    return (
      painted: tester.getRect(label).width,
      // The tile's padding gives the label 4 dp either side.
      box: tester.getSize(card).width - 8,
      lines: (paragraph.size.height / oneLine.height).round(),
      unscaled: unscaled.width,
    );
  }

  /// The stat labels live inside the tiles' [InkWell]s, so every lookup is
  /// scoped to the tile row rather than the whole dashboard.
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
    'en': ['Expiry', 'Low stock', 'Treatments'],
    'de': ['Ablauf', 'Wenig Vorrat', 'Behandlungen'],
    'it': ['Scadenza', 'Scorte basse', 'Trattamenti'],
  };

  // 1.06 is where German lost the fight; 1.15 and 1.3 are the second notch
  // and the top of Android's font-size slider, and 2.0 is the accessibility
  // ceiling the app claims to support.
  const scales = <double>[1.0, 1.06, 1.3, 1.5, 2.0];

  for (final entry in labels.entries) {
    for (final scale in scales) {
      testWidgets('stat tile labels stay whole in ${entry.key} at ${scale}x', (
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
          locale: Locale(entry.key),
        );
        await tester.pumpAndSettle();

        // Measure all three before asserting any, so a failure report
        // carries the whole row's numbers, not only the first to break.
        final measured =
            <
              String,
              ({double painted, double box, int lines, double unscaled})
            >{};
        for (final label in entry.value) {
          final finder = statLabel(label);
          expect(finder, findsOneWidget, reason: 'missing stat label $label');
          measured[label] = measure(tester, finder);
        }
        printOnFailure(
          measured.entries
              .map(
                (m) =>
                    '"${m.key}": painted ${m.value.painted.toStringAsFixed(1)} dp '
                    'on ${m.value.lines} line(s), box ${m.value.box.toStringAsFixed(1)} dp, '
                    'unscaled ${m.value.unscaled.toStringAsFixed(1)} dp',
              )
              .join('\n'),
        );

        for (final label in entry.value) {
          final m = measured[label]!;
          expect(
            m.lines,
            1,
            reason:
                '"$label" was broken across ${m.lines} lines at ${scale}x; a '
                'word wider than its line is broken mid-word, which is the '
                'reported bug',
          );
          expect(
            m.painted,
            lessThanOrEqualTo(m.box + 0.5),
            reason:
                '"$label" painted ${m.painted.toStringAsFixed(1)} dp into a '
                '${m.box.toStringAsFixed(1)} dp tile at ${scale}x',
          );
          expect(
            m.painted,
            greaterThanOrEqualTo(m.unscaled - 0.5),
            reason:
                '"$label" shrank below its unscaled '
                '${m.unscaled.toStringAsFixed(1)} dp at ${scale}x: shrinking '
                'to fit must never undo the user\'s font-size setting',
          );
        }
      });
    }
  }
}
