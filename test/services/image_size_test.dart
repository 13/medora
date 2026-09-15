import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/image_size.dart';

void main() {
  testWidgets('reads the upright size of an EXIF-rotated JPEG', (tester) async {
    // 40x20 pixels stored, EXIF orientation 6 (rotate 90° clockwise): the
    // engine's ImageDescriptor reports the displayed, upright size, matching
    // ML Kit's box coordinates.
    final size = await tester.runAsync(
      () => readImageSize('test/fixtures/exif_orientation_6.jpg'),
    );
    expect(size, const Size(20, 40));
  });

  testWidgets('decodes an upright downscaled RGBA copy for barcode retry', (
    tester,
  ) async {
    const path = 'test/fixtures/exif_orientation_6.jpg';
    final small = await tester.runAsync(() => decodeDownscaledRgba(path, 20));
    expect(small, isNotNull);
    // Upright 20x40 scaled so the longer side is 20: the same orientation
    // as readImageSize, so boxes scale back by width and height ratios.
    expect((small!.width, small.height), (10, 20));
    expect(small.rgba.length, 10 * 20 * 4);

    final notLarger = await tester.runAsync(
      () => decodeDownscaledRgba(path, 40),
    );
    expect(notLarger, isNull);
  });
}
