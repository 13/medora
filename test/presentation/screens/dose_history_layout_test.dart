/// The dose history list outside its comfortable case: a 360 dp phone,
/// German and Italian, and a 1.6x text scale.
///
/// Real fonts are mandatory here: `flutter_test` renders every glyph as a
/// 1-em box unless they are registered, which makes an 11 sp status label
/// about three times as wide as on a device (see test/helpers/fonts.dart),
/// and `loadAppFonts()` is only wired up automatically under test/goldens/.
/// A width assertion measured in the test font would fail for a reason that
/// does not exist on a phone.
///
/// 1.6x is the ceiling asserted here, not the ceiling the app claims. At
/// 2.0x German still breaks "Tachipirina" mid-word - the name wants 174.0 dp
/// of a row that has 260 dp to share - and the trailing cap cannot reach
/// that case: it would have to fall to 0.27 of the slot, close enough to
/// German's natural 0.25 at 1.0x that the column would start shrinking at
/// the default font size. That is a worse trade than a broken word at twice
/// the default scale, so it is left, deliberately, for the row to be
/// redesigned rather than squeezed.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/screens/dose/dose_history_screen.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);
  final today = DateTime(2026, 3, 4);

  setUpAll(loadAppFonts);

  /// One row per status, so the trailing column is measured at every width
  /// it can take: German "Überspringen" is the widest status label, and a
  /// taken dose stacks a third line under the scheduled time.
  List<DoseLog> historyDoses() => [
    DoseLog(
      id: 'd1',
      prescriptionId: 'p1',
      scheduledTime: today.add(const Duration(hours: 8)),
      status: DoseStatus.skipped,
      medicationName: 'Tachipirina 1000',
      dosageAmount: 1,
      medicationUnit: 'tablets',
      treatmentName: 'Influenza',
      patientTags: const ['Ben'],
    ),
    DoseLog(
      id: 'd2',
      prescriptionId: 'p1',
      scheduledTime: today.add(const Duration(hours: 12)),
      status: DoseStatus.taken,
      takenTime: today.add(const Duration(hours: 12, minutes: 5)),
      medicationName: 'Bentelan',
      dosageAmount: 1,
      medicationUnit: 'tablets',
      treatmentName: 'Influenza',
    ),
    DoseLog(
      id: 'd3',
      prescriptionId: 'p1',
      scheduledTime: today.add(const Duration(hours: 16)),
      status: DoseStatus.missed,
      medicationName: 'Moment 200',
      dosageAmount: 1,
      medicationUnit: 'tablets',
    ),
    DoseLog(
      id: 'd4',
      prescriptionId: 'p1',
      scheduledTime: today.add(const Duration(hours: 20)),
      medicationName: 'Brufen 600',
      dosageAmount: 1,
      medicationUnit: 'tablets',
    ),
  ];

  /// The screen reads its range off [nowProvider] and then loads it through
  /// [doseHistoryProvider]; overriding the family answers every range, so
  /// the test needs no database and no clock of its own.
  List<Override> overrides() => [
    nowProvider.overrideWithValue(() => now),
    doseHistoryProvider.overrideWith((ref, range) async => historyDoses()),
  ];

  Future<void> pumpHistory(
    WidgetTester tester, {
    required String lang,
    required double scale,
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(
      tester,
      Builder(
        // Copy the ambient MediaQuery rather than replacing it: a bare
        // `MediaQueryData` would also zero the viewport size and padding,
        // and the test would then be measuring a different page.
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: const DoseHistoryScreen(),
        ),
      ),
      overrides: overrides(),
      locale: Locale(lang),
    );
    await tester.pumpAndSettle();
  }

  /// What a label needs against the box it was actually given.
  ///
  /// A paragraph handed too little width does not report a bigger size: it
  /// breaks mid-word, ellipsizes, or - the default - clips, all in silence,
  /// so `takeException` stays null and a viewport sweep stays happy while
  /// the user reads one glyph per line. The number that decides it is the
  /// widest run that cannot be broken - the longest word at this
  /// paragraph's own text scale, which `TextPainter.minIntrinsicWidth`
  /// reports - against `constraints.maxWidth`, the box the row handed it.
  ({double needs, double box, double painted, double unscaled}) measure(
    WidgetTester tester,
    Finder label,
  ) {
    final paragraph = tester.renderObject<RenderParagraph>(label);
    final scaled = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      strutStyle: paragraph.strutStyle,
      textAlign: paragraph.textAlign,
      locale: paragraph.locale,
    )..layout();
    final unscaled = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: TextScaler.noScaling,
    )..layout();
    final needs = scaled.minIntrinsicWidth;
    scaled.dispose();
    final result = (
      needs: needs,
      box: paragraph.constraints.maxWidth,
      painted: tester.getRect(label).width,
      unscaled: unscaled.width,
    );
    unscaled.dispose();
    return result;
  }

  const names = ['Tachipirina 1000', 'Bentelan', 'Moment 200', 'Brufen 600'];

  /// The widest status label each locale can put in the trailing column -
  /// the one that starves the title hardest.
  const widestStatus = {'de': 'Überspringen', 'it': 'Salta', 'en': 'Skip'};

  for (final lang in const ['de', 'it']) {
    testWidgets('a history row keeps its medication name at 360 dp, $lang, '
        '1.6x', (tester) async {
      await pumpHistory(tester, lang: lang, scale: 1.6);

      // Nothing is under test unless the rows are actually built: the list
      // is a ListView.builder behind an AsyncValueView, and an empty or
      // still-loading screen would pass every assertion below.
      for (final name in names) {
        expect(
          find.text(name),
          findsOneWidget,
          reason: 'the history row for "$name" is not on screen',
        );
      }
      expect(
        find.text(widestStatus[lang]!),
        findsOneWidget,
        reason:
            'the trailing status column is not showing '
            '"${widestStatus[lang]}", so the column that takes the row is '
            'not on screen to be measured',
      );

      final measured = {
        for (final name in names) name: measure(tester, find.text(name)),
      };
      printOnFailure(
        measured.entries
            .map(
              (m) =>
                  '"${m.key}": needs ${m.value.needs.toStringAsFixed(1)} dp '
                  'for its longest word, box ${m.value.box.toStringAsFixed(1)} dp, '
                  'painted ${m.value.painted.toStringAsFixed(1)} dp',
            )
            .join('\n'),
      );

      for (final name in names) {
        final m = measured[name]!;
        expect(
          m.box,
          greaterThan(0),
          reason:
              '"$name" was given a ${m.box.toStringAsFixed(1)} dp box: the '
              'trailing column took the whole row, and neither maxLines nor '
              'an ellipsis can rescue a 0 dp title',
        );
        expect(
          m.needs,
          lessThanOrEqualTo(m.box + 0.5),
          reason:
              '"$name" needs ${m.needs.toStringAsFixed(1)} dp for its longest '
              'unbreakable run but the trailing column left it '
              '${m.box.toStringAsFixed(1)} dp, so the name is broken mid-word '
              'or clipped - silently, which is why no earlier test caught it',
        );
      }

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the trailing column is not shrunk at an ordinary scale', (
    tester,
  ) async {
    // English at 412 dp / 1.0x is the goldens' own configuration. A cap that
    // bites here would repaint every row the goldens photograph and would be
    // undoing a font size the user never changed.
    await pumpHistory(tester, lang: 'en', scale: 1.0, width: 412);

    for (final label in [widestStatus['en']!, '20:00', '@ 12:05']) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: 'missing trailing label $label');
      final m = measure(tester, finder);
      expect(
        m.painted,
        greaterThanOrEqualTo(m.unscaled - 0.5),
        reason:
            '"$label" painted ${m.painted.toStringAsFixed(1)} dp against an '
            'unscaled ${m.unscaled.toStringAsFixed(1)} dp: the guard must be '
            'inert at the scale the goldens are recorded at',
      );
    }

    expect(tester.takeException(), isNull);
  });
}
