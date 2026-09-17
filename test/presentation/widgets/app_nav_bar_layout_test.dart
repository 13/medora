/// The bottom bar's labels in the app's real fonts: always whole words, on
/// one line, and never smaller than 0.85x of their 1.0x size.
///
/// `NavigationBar` caps its labels at 1.3x and gives each one a slot of a
/// quarter of the screen. "Behandlungen" is 88.8 dp at 1.0x: in a 90 dp slot
/// on a 360 dp phone it was broken mid-word from about 1.02x, and in an 80 dp
/// slot on a 320 dp phone it was broken even at 1.0x. Clipped or broken text
/// throws nothing, so this measures each label's widest unbreakable run and
/// its whole width against its slot.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/app_nav_bar.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/text_fit.dart';

void main() {
  setUpAll(loadAppFonts);

  /// The unscaled label size of the Material 3 bar (labelMedium).
  const baseFontSize = 12.0;

  Future<void> pumpBar(
    WidgetTester tester, {
    required double width,
    required String locale,
    required double scale,
    int selected = 2,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMedoraApp(
      tester,
      withTextScale(
        scale,
        Scaffold(bottomNavigationBar: AppNavBar(currentIndex: selected)),
      ),
      locale: Locale(locale),
    );
    await tester.pumpAndSettle();
  }

  List<String> labelsOf(String locale) {
    final l10n = lookupAppLocalizations(Locale(locale));
    return [
      l10n.navHome,
      l10n.navMedications,
      l10n.navTreatments,
      l10n.navDoses,
    ];
  }

  RenderParagraph paragraphOf(WidgetTester tester, String label) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
          matching: find.byType(RichText),
          matchRoot: true,
        ),
      );

  /// The label's rendered font size in logical pixels.
  double pxOf(RenderParagraph p) {
    final fontSize = p.text.style?.fontSize ?? baseFontSize;
    return p.textScaler.scale(fontSize);
  }

  /// The smallest a label may be drawn: 0.85x of its 1.0x size.
  const floorFontSize = baseFontSize * 0.85;

  for (final width in const [320.0, 360.0]) {
    final slot = width / 4;
    for (final locale in const ['en', 'de', 'it']) {
      for (final scale in const [1.0, 1.02, 1.1, 1.2, 1.3, 1.6, 2.0]) {
        testWidgets('${width.toInt()} dp, $locale, ${scale}x: every label is '
            'a whole word on one line, at least 0.85x', (tester) async {
          await pumpBar(tester, width: width, locale: locale, scale: scale);
          expect(tester.takeException(), isNull);
          final sizes = <double>[];
          for (final label in labelsOf(locale)) {
            final where = '"$label" (${width.toInt()} dp, $locale, ${scale}x)';
            final fit = measureText(
              tester,
              find.descendant(
                of: find.byType(NavigationBar),
                matching: find.text(label),
              ),
            );
            printOnFailure('$where: $fit, slot $slot');
            // The paragraph may use the whole slot, and no more.
            expect(fit.maxWidth, lessThanOrEqualTo(slot + 0.01));
            // The widest unbreakable run fits: no word is broken.
            expect(
              fit.minIntrinsic,
              lessThanOrEqualTo(fit.maxWidth + 0.01),
              reason: '$where is broken inside a word',
            );
            expect(
              fit.maxIntrinsic,
              lessThanOrEqualTo(fit.maxWidth + 0.01),
              reason: '$where does not fit on one line',
            );
            final p = paragraphOf(tester, label);
            final oneLine = TextPainter(
              text: p.text,
              textDirection: p.textDirection,
              textScaler: p.textScaler,
            )..layout();
            addTearDown(oneLine.dispose);
            expect(
              p.size.height,
              lessThanOrEqualTo(oneLine.height + 0.01),
              reason: '$where is not on one line',
            );
            final px = pxOf(p);
            printOnFailure('$where: ${px.toStringAsFixed(2)} px');
            expect(
              px,
              greaterThanOrEqualTo(floorFontSize - 0.01),
              reason: '$where is smaller than 0.85x',
            );
            if (width >= 360) {
              // Every label fits a 90 dp slot at 1.0x, so none is shrunk
              // below its 1.0x size there.
              expect(
                px,
                greaterThanOrEqualTo(baseFontSize - 0.01),
                reason: '$where is smaller than at 1.0x',
              );
            }
            // Never larger than Flutter's own 1.3x cap for these labels.
            expect(px, lessThanOrEqualTo(baseFontSize * 1.3 + 0.01));
            sizes.add(px);
          }
          // One size for the whole bar, so the labels still read as a set.
          expect(sizes.toSet(), hasLength(1));
        });
      }
    }
  }

  testWidgets('labels that fit keep the size Flutter gives them', (
    tester,
  ) async {
    // English at 412 dp fits even at the 1.3x cap.
    await pumpBar(tester, width: 412, locale: 'en', scale: 2.0);
    final p = paragraphOf(tester, 'Treatments');
    expect(pxOf(p), moreOrLessEquals(baseFontSize * 1.3, epsilon: 0.01));

    await pumpBar(tester, width: 360, locale: 'de', scale: 1.0);
    expect(
      pxOf(paragraphOf(tester, 'Behandlungen')),
      moreOrLessEquals(baseFontSize, epsilon: 0.01),
    );
  });

  testWidgets('a label that does not fit is shrunk just enough', (
    tester,
  ) async {
    await pumpBar(tester, width: 360, locale: 'de', scale: 1.6);
    final fit = measureText(
      tester,
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Behandlungen'),
      ),
    );
    // The widest label fills its slot to within a fraction of a dp.
    expect(fit.maxIntrinsic, greaterThan(fit.maxWidth - 0.5));
    expect(pxOf(paragraphOf(tester, 'Behandlungen')), greaterThan(12));
  });

  testWidgets('on a 320 dp phone, German is shrunk below 1.0x just enough', (
    tester,
  ) async {
    // 80 dp slots, and "Behandlungen" is 88.8 dp at 1.0x: it needs about
    // 0.9x, which is above the 0.85x floor.
    await pumpBar(tester, width: 320, locale: 'de', scale: 1.0);
    final fit = measureText(
      tester,
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Behandlungen'),
      ),
    );
    expect(fit.maxIntrinsic, greaterThan(fit.maxWidth - 0.5));
    final px = pxOf(paragraphOf(tester, 'Behandlungen'));
    expect(px, lessThan(baseFontSize));
    expect(px, greaterThan(floorFontSize));
  });

  testWidgets('a label that cannot fit even at 0.85x stays at 0.85x', (
    tester,
  ) async {
    // 280 dp: 70 dp slots, and "Behandlungen" is about 75.5 dp at 0.85x.
    // The floor wins; the label is not made any smaller.
    await pumpBar(tester, width: 280, locale: 'de', scale: 1.6);
    for (final label in labelsOf('de')) {
      expect(
        pxOf(paragraphOf(tester, label)),
        moreOrLessEquals(floorFontSize, epsilon: 0.01),
        reason: label,
      );
    }
  });

  testWidgets('the long-press tooltip keeps the full label', (tester) async {
    await pumpBar(tester, width: 360, locale: 'de', scale: 1.6);
    expect(find.byTooltip('Behandlungen'), findsOneWidget);
  });
}
