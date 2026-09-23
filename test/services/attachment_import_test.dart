import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:path/path.dart' as p;

Uint8List _jpeg(int w, int h, {img.ExifData? exif}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 100, 50));
  if (exif != null) image.exif = exif;
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  test('a large photo is scaled to a 2400 px long edge', () {
    final result =
        AttachmentImport.prepare(_jpeg(4000, 3000), nameOrPath: 'IMG_1.jpg')
            as Imported;
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.width, 2400);
    expect(decoded.height, 1800);
    expect(result.kind, AttachmentKind.photo);
    expect(result.mime, 'image/jpeg');
    expect(result.sha256, sha256.convert(result.bytes).toString());
  });

  test('a small photo keeps its size', () {
    final result =
        AttachmentImport.prepare(_jpeg(800, 600), nameOrPath: 'a.jpg')
            as Imported;
    expect(img.decodeJpg(result.bytes)!.width, 800);
  });

  test('EXIF, including GPS, is removed; orientation is baked in', () {
    final exif = img.ExifData();
    exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(46, 1);
    exif.imageIfd['Orientation'] = img.IfdValueShort(6);
    final result =
        AttachmentImport.prepare(
              _jpeg(400, 200, exif: exif),
              nameOrPath: 'a.jpg',
            )
            as Imported;
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
    expect(decoded.exif.imageIfd['Orientation'], isNull);
    // Orientation 6 = rotate 90° clockwise: 400x200 becomes 200x400.
    expect(decoded.width, 200);
    expect(decoded.height, 400);
  });

  test('a real EXIF-rotated photo (fixture) loses its orientation tag and is '
      'physically rotated', () {
    // The fixture is stored as 40x20 with an orientation-6 tag (rotate
    // 90° clockwise), so it displays as a 20x40 portrait.
    final raw = File('test/fixtures/exif_orientation_6.jpg').readAsBytesSync();
    final result =
        AttachmentImport.prepare(raw, nameOrPath: 'exif_orientation_6.jpg')
            as Imported;
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.exif.imageIfd['Orientation'], isNull);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
    expect(decoded.width, 20);
    expect(decoded.height, 40);
  });

  test('a PDF is kept byte for byte', () {
    final pdf = Uint8List.fromList('%PDF-1.4\n%fake\n'.codeUnits);
    final result =
        AttachmentImport.prepare(pdf, nameOrPath: 'rezept.pdf') as Imported;
    expect(result.bytes, pdf);
    expect(result.kind, AttachmentKind.pdf);
    expect(result.mime, 'application/pdf');
    expect(result.originalName, 'rezept.pdf');
  });

  test('a PDF over 20 MB is refused', () {
    final big = Uint8List(AttachmentImport.maxPdfBytes + 1)
      ..setAll(0, '%PDF-'.codeUnits);
    expect(
      (AttachmentImport.prepare(big, nameOrPath: 'x.pdf') as ImportRefused)
          .reason,
      ImportRefusal.tooLarge,
    );
  });

  test('other files are refused; broken images are unreadable', () {
    expect(
      (AttachmentImport.prepare(
                Uint8List.fromList([1, 2, 3]),
                nameOrPath: 'x.docx',
              )
              as ImportRefused)
          .reason,
      ImportRefusal.unsupported,
    );
    expect(
      (AttachmentImport.prepare(
                Uint8List.fromList([0xFF, 0xD8, 0, 0]),
                nameOrPath: 'x.jpg',
              )
              as ImportRefused)
          .reason,
      ImportRefusal.unreadable,
    );
  });

  test('fromPath reads a file from disk and prepares it', () async {
    final dir = await Directory.systemTemp.createTemp('attachment_import_');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'photo.jpg');
    await File(path).writeAsBytes(_jpeg(4000, 3000));

    final result =
        await AttachmentImport.fromPath(path, originalName: 'IMG_2.jpg')
            as Imported;

    expect(result.kind, AttachmentKind.photo);
    expect(result.originalName, 'IMG_2.jpg');
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.width, 2400);
    expect(decoded.height, 1800);
  });
}
