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
}
