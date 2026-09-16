import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/image_size.dart';
import 'package:medora/services/scan_region.dart';

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

  testWidgets('one decode writes every rotation asked for', (tester) async {
    // Review I1: the stripe pass wrote one rotation per call, so the whole
    // photo was decoded once per rotation. All the rotations come out of a
    // single decode now, and land on the same pixels as a single write.
    final dir = Directory.systemTemp.createTempSync('scan_rot_batch_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = '${dir.path}/marked.png';
    const mark = Rect.fromLTRB(2, 1, 6, 4);
    const photo = Rect.fromLTRB(0, 0, 20, 10);
    await tester.runAsync(
      () => writeMarkedPng(src, width: 20, height: 10, mark: mark),
    );
    final outputs = [
      for (var turns = 0; turns < 4; turns++)
        (quarterTurns: turns, outPath: '${dir.path}/batch_$turns.png'),
    ];

    final written = await tester.runAsync(
      () => writeImageCropRotations(src, photo, outputs),
    );
    expect(written?.crop, photo);
    expect(written?.scale, 1.0);
    for (final output in outputs) {
      final turns = output.quarterTurns;
      final size = await tester.runAsync(() => readImageSize(output.outPath));
      expect(
        size,
        turns.isEven ? const Size(20, 10) : const Size(10, 20),
        reason: 'turns $turns',
      );
      final box = await tester.runAsync(() => markBoxIn(output.outPath));
      expect(
        unrotateBox(
          box!,
          quarterTurns: turns,
          crop: written!.crop,
          scale: written.scale,
        ),
        mark,
        reason: 'turns $turns',
      );
    }
  });

  testWidgets('a batch of rotations obeys the decode cap, and an empty crop '
      'writes nothing', (tester) async {
    final dir = Directory.systemTemp.createTempSync('scan_rot_batch_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = '${dir.path}/marked.png';
    const photo = Rect.fromLTRB(0, 0, 20, 10);
    await tester.runAsync(
      () => writeMarkedPng(
        src,
        width: 20,
        height: 10,
        mark: const Rect.fromLTRB(2, 1, 6, 4),
      ),
    );

    final capped = await tester.runAsync(
      () => writeImageCropRotations(src, photo, [
        (quarterTurns: 0, outPath: '${dir.path}/cap_0.png'),
        (quarterTurns: 1, outPath: '${dir.path}/cap_1.png'),
      ], maxDecodeSide: 10),
    );
    expect(capped?.crop, photo);
    expect(capped?.scale, 0.5);
    expect(
      await tester.runAsync(() => readImageSize('${dir.path}/cap_0.png')),
      const Size(10, 5),
    );
    expect(
      await tester.runAsync(() => readImageSize('${dir.path}/cap_1.png')),
      const Size(5, 10),
    );

    final outside = '${dir.path}/outside.png';
    final empty = await tester.runAsync(
      () => writeImageCropRotations(src, const Rect.fromLTRB(25, 0, 30, 10), [
        (quarterTurns: 0, outPath: outside),
      ]),
    );
    expect(empty, isNull);
    expect(File(outside).existsSync(), isFalse);
  });

  testWidgets('every rotation maps back to the same pixels', (tester) async {
    // Review I2: the dimension tests above would also pass if the crop were
    // drawn unrotated, mirrored or turned the wrong way. This one reads the
    // written pixels back and checks unrotateBox is the exact inverse.
    final dir = Directory.systemTemp.createTempSync('scan_rot_pixels_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = '${dir.path}/marked.png';
    const mark = Rect.fromLTRB(2, 1, 6, 4);
    const photo = Rect.fromLTRB(0, 0, 20, 10);
    await tester.runAsync(
      () => writeMarkedPng(src, width: 20, height: 10, mark: mark),
    );

    for (var turns = 0; turns < 4; turns++) {
      final out = '${dir.path}/rot_$turns.png';
      final written = await tester.runAsync(
        () => writeImageCrop(src, photo, out, quarterTurns: turns),
      );
      expect(written?.crop, photo, reason: 'turns $turns');
      expect(written?.scale, 1.0, reason: 'turns $turns');
      final size = await tester.runAsync(() => readImageSize(out));
      expect(
        size,
        turns.isEven ? const Size(20, 10) : const Size(10, 20),
        reason: 'turns $turns',
      );
      final box = await tester.runAsync(() => markBoxIn(out));
      expect(
        unrotateBox(
          box!,
          quarterTurns: turns,
          crop: written!.crop,
          scale: written.scale,
        ),
        mark,
        reason: 'turns $turns',
      );
    }
  });

  testWidgets('a downscaled rotation maps back to the same pixels', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('scan_rot_pixels_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = '${dir.path}/marked.png';
    const mark = Rect.fromLTRB(2, 1, 6, 4);
    const photo = Rect.fromLTRB(0, 0, 20, 10);
    await tester.runAsync(
      () => writeMarkedPng(src, width: 20, height: 10, mark: mark),
    );

    for (var turns = 0; turns < 4; turns++) {
      final out = '${dir.path}/half_$turns.png';
      final written = await tester.runAsync(
        () => writeImageCrop(
          src,
          photo,
          out,
          maxDecodeSide: 10,
          quarterTurns: turns,
        ),
      );
      expect(written?.scale, 0.5, reason: 'turns $turns');
      final box = await tester.runAsync(() => markBoxIn(out));
      // Half a photo pixel of the mark is lost to the downscale, so the
      // box comes back one pixel shorter at the top; still the inverse.
      expect(
        unrotateBox(
          box!,
          quarterTurns: turns,
          crop: written!.crop,
          scale: written.scale,
        ),
        const Rect.fromLTRB(2, 2, 6, 4),
        reason: 'turns $turns',
      );
    }
  });
}

/// Writes a [width] x [height] white PNG at [path] with a red rectangle at
/// [mark], so the rotation of a crop can be checked on the pixels.
Future<void> writeMarkedPng(
  String path, {
  required int width,
  required int height,
  required Rect mark,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(mark, Paint()..color = const Color(0xFFFF0000));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final png = await image.toByteData(format: ImageByteFormat.png);
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// The box of the red pixels of the PNG at [path], right and bottom
/// exclusive — the shape ML Kit reports a box in that PNG.
Future<Rect> markBoxIn(String path) async {
  final bytes = await File(path).readAsBytes();
  final buffer = await ImmutableBuffer.fromUint8List(bytes);
  ImageDescriptor? descriptor;
  Codec? codec;
  Image? image;
  try {
    descriptor = await ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    var left = image.width, top = image.height, right = -1, bottom = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 4;
        final r = data!.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        if (r > 128 && g < 128 && b < 128) {
          if (x < left) left = x;
          if (y < top) top = y;
          if (x > right) right = x;
          if (y > bottom) bottom = y;
        }
      }
    }
    expect(right, greaterThanOrEqualTo(left), reason: 'no mark in $path');
    return Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      (right + 1).toDouble(),
      (bottom + 1).toDouble(),
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
