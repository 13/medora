import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/code39.dart';

void main() {
  testWidgets('paints an encodable barcode without error', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: 2.5),
          child: SizedBox(width: 320, child: Code39Barcode('0410A1234567890')),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders nothing for data Code 39 cannot encode', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 320, child: Code39Barcode('lower#case')),
      ),
    );
    expect(find.byType(SizedBox).evaluate().isNotEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('encodes start/stop and one character per 9 elements + gap', () {
    final bars = Code39.encode('A')!;
    // "*A*": 3 characters × (6 narrow + 3 wide = 6 + 9 = 15 modules) + 2 gaps.
    expect(bars.length, 3 * 15 + 2);
    // A character starts and ends with a bar.
    expect(bars.first, isTrue);
    expect(bars.last, isTrue);
  });

  test('A encodes as 100001001 (bar and space alternate, 1 = wide)', () {
    final bars = Code39.encode('A')!;
    // Skip "*" (15 modules) and its gap (1 module).
    final a = bars.sublist(16, 31);
    // A = 100001001 → bar W, sp N, bar N, sp N, bar N, sp W, bar N, sp N, bar W
    expect(a, [
      true, true, true, false, true, false, true, false, false, false, //
      true, false, true, true, true,
    ]);
  });

  test('digits and upper-case letters of an NRE and a tax code encode', () {
    expect(Code39.encode('0410A1234567890'), isNotNull);
    expect(Code39.encode('RSSMRA85T10A562S'), isNotNull);
  });

  test('lower case and unsupported symbols do not', () {
    expect(Code39.encode('a'), isNull);
    expect(Code39.encode('#'), isNull);
  });

  test('darkRuns collapses each run of consecutive dark modules for A', () {
    final bars = Code39.encode('A')!;
    // Skip "*" (15 modules) and its gap (1 module), as above.
    final a = bars.sublist(16, 31);
    // 100001001: wide bar(3), narrow bar(1), narrow bar(1), narrow bar(1),
    // wide bar(3) — one run per bar, not one rect per module.
    expect(Code39.darkRuns(a), [(0, 3), (4, 1), (6, 1), (10, 1), (12, 3)]);
  });

  group('Code39.layout', () {
    // (width, dpr) pairs a real phone/tablet screen can present the
    // barcode at, including a narrow one (300, 287) that used to starve
    // the quiet zone.
    const widths = [
      (360.0, 3.0),
      (300.0, 3.0),
      (600.0, 2.0),
      (780.0, 3.0),
      (287.0, 1.0),
      (411.0, 2.625),
    ];

    for (final modules in [271, 287]) {
      for (final (width, dpr) in widths) {
        test(
          'width=$width dpr=$dpr modules=$modules keeps a real quiet zone',
          () {
            final layout = Code39.layout(
              width: width,
              dpr: dpr,
              modules: modules,
            );

            // The quiet zone is always at least 16dp and at least 10
            // modules, whether or not the bars themselves fit.
            expect(layout.quietZone, greaterThanOrEqualTo(16));
            expect(
              layout.quietZone,
              greaterThanOrEqualTo(10 * layout.module - 1e-9),
            );

            // The module is a whole number of device pixels, at least one.
            final devicePixels = layout.module * dpr;
            expect(devicePixels, closeTo(devicePixels.roundToDouble(), 1e-9));
            expect(devicePixels, greaterThanOrEqualTo(1 - 1e-9));

            final fits =
                modules * layout.module + 2 * layout.quietZone <= width;
            if (fits) {
              // Bars start clear of the left quiet zone and end clear of
              // the right one — never spreading into either.
              expect(
                layout.left,
                greaterThanOrEqualTo(layout.quietZone - 1e-9),
              );
              expect(
                layout.left + modules * layout.module,
                lessThanOrEqualTo(width - layout.quietZone + 1e-9),
              );
            }
          },
        );
      }
    }

    test('287 modules at (287,1) shrinks to a 1px module and still does not '
        'fit', () {
      final layout = Code39.layout(width: 287, dpr: 1, modules: 287);
      expect(layout.module * 1, closeTo(1, 1e-9));
      final fits = 287 * layout.module + 2 * layout.quietZone <= 287;
      expect(fits, isFalse);
    });
  });

  testWidgets('a too-narrow screen never paints outside the widget (clipped)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 50, child: Code39Barcode('0410A1234567890')),
      ),
    );
    expect(find.byType(ClipRect), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
