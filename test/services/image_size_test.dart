import 'dart:io';
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

  testWidgets('writes an upright crop of the photo as a PNG', (tester) async {
    const path = 'test/fixtures/exif_orientation_6.jpg';
    final dir = Directory.systemTemp.createTempSync('scan_crop_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/crop.png';

    final written = await tester.runAsync(
      () => writeImageCrop(path, const Rect.fromLTRB(4.5, 10.2, 30, 30), out),
    );
    // Rounded out to whole pixels and clamped to the upright 20x40 image;
    // not larger than the decode cap, so at full resolution.
    expect(written?.crop, const Rect.fromLTRB(4, 10, 20, 30));
    expect(written?.scale, 1.0);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(16, 20));

    final empty = await tester.runAsync(
      () => writeImageCrop(path, const Rect.fromLTRB(25, 0, 30, 10), out),
    );
    expect(empty, isNull);
  });

  testWidgets('a photo over the decode cap is cropped from a downscaled '
      'decode', (tester) async {
    // Review I3: a 108 MP gallery photo must not be decoded at full size.
    const path = 'test/fixtures/exif_orientation_6.jpg';
    final dir = Directory.systemTemp.createTempSync('scan_crop_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/crop.png';

    final written = await tester.runAsync(
      () => writeImageCrop(
        path,
        const Rect.fromLTRB(4, 10, 20, 30),
        out,
        maxDecodeSide: 20,
      ),
    );
    // Upright 20x40 decoded at 10x20: the crop in photo pixels is kept,
    // the PNG holds it at half size.
    expect(written?.crop, const Rect.fromLTRB(4, 10, 20, 30));
    expect(written?.scale, 0.5);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(8, 10));
  });

  test('cropDecodeScale caps the longer side', () {
    expect(cropDecodeScale(3000, 4000, 4096), 1.0);
    expect(cropDecodeScale(4096, 3000, 4096), 1.0);
    expect(cropDecodeScale(12000, 9000, 4096), 4096 / 12000);
    expect(cropDecodeScale(9000, 12000, 4096), 4096 / 12000);
    expect(regionMaxDecodeSide, 4096);
  });

  testWidgets('a quarter turn swaps the written PNG dimensions', (
    tester,
  ) async {
    const path = 'test/fixtures/exif_orientation_6.jpg'; // upright 20x40
    final dir = Directory.systemTemp.createTempSync('scan_rot_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/rot.png';

    final written = await tester.runAsync(
      () => writeImageCrop(
        path,
        const Rect.fromLTRB(0, 0, 20, 40),
        out,
        quarterTurns: 1,
      ),
    );
    // The crop stays in photo pixels; only the PNG is turned.
    expect(written?.crop, const Rect.fromLTRB(0, 0, 20, 40));
    expect(written?.scale, 1.0);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(40, 20));
  });

  testWidgets('a rotated crop obeys the decode cap', (tester) async {
    const path = 'test/fixtures/exif_orientation_6.jpg';
    final dir = Directory.systemTemp.createTempSync('scan_rot_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/rot.png';

    final written = await tester.runAsync(
      () => writeImageCrop(
        path,
        const Rect.fromLTRB(0, 0, 20, 40),
        out,
        maxDecodeSide: 20,
        quarterTurns: 3,
      ),
    );
    expect(written?.crop, const Rect.fromLTRB(0, 0, 20, 40));
    expect(written?.scale, 0.5);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(20, 10));
  });
}
