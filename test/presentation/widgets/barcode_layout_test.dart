import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/barcode_layout.dart';

void main() {
  group('BarcodeLayout.layout', () {
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
            final layout = BarcodeLayout.layout(
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
      final layout = BarcodeLayout.layout(width: 287, dpr: 1, modules: 287);
      expect(layout.module * 1, closeTo(1, 1e-9));
      final fits = 287 * layout.module + 2 * layout.quietZone <= 287;
      expect(fits, isFalse);
    });
  });

  test('darkRuns collapses each run of consecutive dark modules', () {
    // 100001001: wide bar(3), narrow bar(1), narrow bar(1), narrow bar(1),
    // wide bar(3) — one run per bar, not one rect per module.
    const a = [
      true, true, true, false, true, false, true, false, false, false, //
      true, false, true, true, true,
    ];
    expect(BarcodeLayout.darkRuns(a), [
      (0, 3),
      (4, 1),
      (6, 1),
      (10, 1),
      (12, 3),
    ]);
  });
}
