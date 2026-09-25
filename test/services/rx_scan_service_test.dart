// Invented data only (see test/fixtures/rx_scan):
// patient ROSSI MARIO / RSSMRA85T10A562S, doctor BIANCHI LUCA /
// BNCLCU70A01A952Z, SSN NRE 041A0 + 0012345678.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/pdf_page_port.dart';
import 'package:medora/services/rx_scan_service.dart';
import 'package:medora/services/scanner_ports.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_scanner_ports.dart';

const _patient = 'RSSMRA85T10A562S';
const _doctor = 'BNCLCU70A01A952Z';

/// A photo small enough to skip the size/pixel refusal, with a real (if
/// tiny) JPEG so `readImageSize`/`writeImageCropRotations` can decode it.
const _photoPath = 'test/fixtures/exif_orientation_6.jpg';

Future<Set<String>> _noKnownTaxCodes() async => const {};

/// [PdfPagePort] that answers from a script instead of `pdfrx`.
class FakePdfPagePort implements PdfPagePort {
  FakePdfPagePort(this.result);

  /// What `read` returns, or throws when null.
  final PdfRead? result;

  final calls = <String>[];

  @override
  Future<PdfRead> read(String pdfPath, String outputDir) async {
    calls.add(pdfPath);
    final r = result;
    if (r == null) throw StateError('pdf read failed');
    return r;
  }
}

/// A path to a small file on disk under [dir]: `scanPdf`'s own size check
/// reads its length before `pdf.read` is ever called, but `FakePdfPagePort`
/// never reads the file itself, so its content doesn't matter.
String _smallFile(Directory dir, [String name = 'doc.pdf']) {
  final file = File(p.join(dir.path, name))..writeAsBytesSync(const [1, 2, 3]);
  return file.path;
}

RxScanService _service({
  required RawBarcodePort barcodes,
  required TextRecognitionPort text,
  required PdfPagePort pdf,
  required Directory tempRoot,
  Future<Set<String>> Function() knownTaxCodes = _noKnownTaxCodes,
  DateTime Function() now = DateTime.now,
}) => RxScanService(
  barcodes: barcodes,
  text: text,
  pdf: pdf,
  knownTaxCodes: knownTaxCodes,
  now: now,
  tempRoot: () async => tempRoot,
);

/// A fresh directory under the system temp dir, handed to the service as
/// its temp root (`rx_scan/` is created inside it) and deleted after the
/// test. Real file I/O, so tests using it run in a plain `test()` (or inside
/// `tester.runAsync`), never in a widget test's fake-async zone.
Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('rx_scan_test_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  group('scanPhoto', () {
    testWidgets('barcodes found only at 90 degrees are used', (tester) async {
      final dir = _tempDir();
      final barcodes = FakeRawBarcodePort(const [
        <String>[], // 0
        [_patient], // 90 - the only rotation that decodes anything
        <String>[], // 180
        <String>[], // 270
      ]);
      final text = FakeTextRecognition(const [<OcrLine>[]]);
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: FakePdfPagePort(null),
      );

      final result = await tester.runAsync(() => service.scanPhoto(_photoPath));

      expect(result!.failed, isFalse);
      expect(result.draft.taxCode, _patient);
      // All four rotations were tried (a lone tax code is not "NRE and tax
      // code"), but only rotation 90 decoded anything.
      expect(barcodes.calls, hasLength(4));
      // Text recognition ran on the rotation that decoded the most
      // barcodes: 90 degrees.
      expect(text.calls, hasLength(1));
      final ocrTarget = text.calls.single as ScanImageFile;
      expect(ocrTarget.path, endsWith('rot_1.png'));
    });

    testWidgets('stops early once an NRE and a tax code are decoded', (
      tester,
    ) async {
      final dir = _tempDir();
      final barcodes = FakeRawBarcodePort(const [
        ['041A0', '0012345678', _patient], // 0: a full NRE and a tax code
        [_doctor], // never reached
      ]);
      final text = FakeTextRecognition(const [<OcrLine>[]]);
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: FakePdfPagePort(null),
      );

      final result = await tester.runAsync(() => service.scanPhoto(_photoPath));

      expect(result!.failed, isFalse);
      expect(result.draft.nre, '041A00012345678');
      expect(result.draft.taxCode, _patient);
      // Rotation 0 alone gave an NRE and a tax code, so 90/180/270 were
      // never tried.
      expect(barcodes.calls, hasLength(1));
      expect(text.calls, hasLength(1));
      final ocrTarget = text.calls.single as ScanImageFile;
      expect(ocrTarget.path, endsWith('rot_0.png'));
    });

    testWidgets('an oversized photo is refused before it is decoded', (
      tester,
    ) async {
      final dir = _tempDir();
      final huge = File('${dir.path}/huge.jpg');
      // Over AttachmentImport.maxPdfBytes (20 MB); content does not matter,
      // the length check runs before any byte is read as an image.
      huge.writeAsBytesSync(Uint8List(21 * 1024 * 1024));
      final barcodes = FakeRawBarcodePort(const [<String>[]]);
      final text = FakeTextRecognition(const [<OcrLine>[]]);
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: FakePdfPagePort(null),
      );

      final result = await tester.runAsync(() => service.scanPhoto(huge.path));

      expect(result!.failed, isTrue);
      expect(result.refusal, ImportRefusal.tooLarge);
      expect(result.draft.isEmpty, isTrue);
      expect(barcodes.calls, isEmpty);
    });

    testWidgets('known tax codes reach the extractor', (tester) async {
      final dir = _tempDir();
      // No role labels in the barcodes themselves: without knownTaxCodes
      // the first code decoded (the doctor's, listed first here) would be
      // taken for the patient, same ambiguity `scanPdf` resolves from text.
      final barcodes = FakeRawBarcodePort(const [
        [_doctor, _patient],
        <String>[],
        <String>[],
        <String>[],
      ]);
      final text = FakeTextRecognition(const [<OcrLine>[]]);
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: FakePdfPagePort(null),
        knownTaxCodes: () async => {_patient},
      );

      final result = await tester.runAsync(() => service.scanPhoto(_photoPath));

      expect(result!.failed, isFalse);
      expect(result.draft.taxCode, _patient);
      expect(result.draft.doctorTaxCode, _doctor);
    });
  });

  group('scanPdf', () {
    test('a text layer is used as-is, with no OCR pass', () async {
      final dir = _tempDir();
      const pdfText =
          'ZUNAME UND NAME DES BETREUTEN:ROSSI MARIO 10/12/1985\n'
          "COGNOME E NOME DELL'ASSISTITO:\n"
          'ZUNAME UND NAME DES ARZTES:BIANCHI LUCA\n'
          'COGNOME E NOME DEL MEDICO:';
      final barcodes = FakeRawBarcodePort(const [
        [_patient],
      ]);
      final text = FakeTextRecognition(const [<OcrLine>[]]);
      final pdf = FakePdfPagePort((
        text: pdfText,
        firstPagePng: '/tmp/page1.png',
        pageCount: 1,
      ));
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: pdf,
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.failed, isFalse);
      expect(result.draft.patientName, 'Rossi Mario');
      expect(result.draft.doctor, 'Bianchi Luca');
      // Barcodes still run on the rendered first page...
      expect(barcodes.calls, hasLength(1));
      expect((barcodes.calls.single as ScanImageFile).path, '/tmp/page1.png');
      // ...but OCR never does: the text layer was not empty.
      expect(text.calls, isEmpty);
    });

    test('no text layer falls back to OCR on the rendered page', () async {
      final dir = _tempDir();
      final barcodes = FakeRawBarcodePort(const [<String>[]]);
      final ocrLines = [
        const OcrLine(_patient, Rect.fromLTWH(0, 0, 100, 10)),
        const OcrLine('ROSSI MARIO', Rect.fromLTWH(0, 20, 100, 10)),
      ];
      final text = FakeTextRecognition([ocrLines]);
      final pdf = FakePdfPagePort((
        text: '',
        firstPagePng: '/tmp/page1.png',
        pageCount: 1,
      ));
      final service = _service(
        tempRoot: dir,
        barcodes: barcodes,
        text: text,
        pdf: pdf,
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.failed, isFalse);
      expect(result.draft.taxCode, _patient);
      expect(text.calls, hasLength(1));
      expect((text.calls.single as ScanImageFile).path, '/tmp/page1.png');
    });

    test('a multi-page PDF reports its page count', () async {
      final dir = _tempDir();
      final service = _service(
        tempRoot: dir,
        barcodes: FakeRawBarcodePort(const [<String>[]]),
        text: FakeTextRecognition(const [<OcrLine>[]]),
        pdf: FakePdfPagePort((
          text: 'ZUNAME UND NAME DES ARZTES:BIANCHI LUCA',
          firstPagePng: '/tmp/page1.png',
          pageCount: 3,
        )),
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.failed, isFalse);
      expect(result.pageCount, 3);
      expect(result.draft.doctor, 'Bianchi Luca');
    });

    test('a PDF without a rendered page still reports its pages', () async {
      final dir = _tempDir();
      final service = _service(
        tempRoot: dir,
        barcodes: FakeRawBarcodePort(const [<String>[]]),
        text: FakeTextRecognition(const [<OcrLine>[]]),
        pdf: FakePdfPagePort((text: '', firstPagePng: null, pageCount: 2)),
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.pageCount, 2);
    });

    test('a photo is one page', () async {
      expect(const RxScanResult(RxDraft()).pageCount, 1);
    });

    test('known tax codes are passed through to the extractor', () async {
      final dir = _tempDir();
      // No role labels: without knownTaxCodes the first code found (the
      // doctor's, printed first here) would be taken for the patient.
      const pdfText = '$_doctor\n$_patient';
      final service = _service(
        tempRoot: dir,
        barcodes: FakeRawBarcodePort(const [<String>[]]),
        text: FakeTextRecognition(const [<OcrLine>[]]),
        pdf: FakePdfPagePort((text: pdfText, firstPagePng: null, pageCount: 1)),
        knownTaxCodes: () async => {_patient},
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.draft.taxCode, _patient);
      expect(result.draft.doctorTaxCode, _doctor);
    });

    test('a port throwing fails the scan with an empty draft', () async {
      final dir = _tempDir();
      final service = _service(
        tempRoot: dir,
        barcodes: FakeRawBarcodePort(const [<String>[]]),
        text: FakeTextRecognition(const [<OcrLine>[]]),
        pdf: FakePdfPagePort(null), // read() throws
      );

      final result = await service.scanPdf(_smallFile(dir));

      expect(result.failed, isTrue);
      expect(result.draft.isEmpty, isTrue);
    });

    test('a PDF over 20 MB is refused before it is read', () async {
      final dir = _tempDir();
      final huge = File(p.join(dir.path, 'huge.pdf'));
      // Over AttachmentImport.maxPdfBytes (20 MB); content does not matter,
      // the length check runs before `pdf.read` is ever called.
      huge.writeAsBytesSync(Uint8List(21 * 1024 * 1024));
      final pdf = FakePdfPagePort(null); // read() would throw if called
      final service = _service(
        tempRoot: dir,
        barcodes: FakeRawBarcodePort(const [<String>[]]),
        text: FakeTextRecognition(const [<OcrLine>[]]),
        pdf: pdf,
      );

      final result = await service.scanPdf(huge.path);

      expect(result.failed, isTrue);
      expect(result.refusal, ImportRefusal.tooLarge);
      expect(result.draft.isEmpty, isTrue);
      expect(pdf.calls, isEmpty);
    });
  });

  group('scan directories', () {
    test(
      'a stale scan directory is swept at the next scan; a fresh one is kept',
      () async {
        final dir = _tempDir();
        final root = Directory(p.join(dir.path, 'rx_scan'))
          ..createSync(recursive: true);
        final base = DateTime(2026, 1, 1, 12);
        final staleStamp = base
            .subtract(const Duration(minutes: 11))
            .millisecondsSinceEpoch;
        final freshStamp = base
            .subtract(const Duration(minutes: 2))
            .millisecondsSinceEpoch;
        final stale = Directory(p.join(root.path, '${staleStamp}_stale'))
          ..createSync();
        final fresh = Directory(p.join(root.path, '${freshStamp}_fresh'))
          ..createSync();
        final service = _service(
          barcodes: FakeRawBarcodePort(const [<String>[]]),
          text: FakeTextRecognition(const [<OcrLine>[]]),
          pdf: FakePdfPagePort((text: '', firstPagePng: null, pageCount: 1)),
          tempRoot: dir,
          now: () => base,
        );

        await service.scanPdf(_smallFile(dir));

        expect(stale.existsSync(), isFalse);
        expect(fresh.existsSync(), isTrue);
      },
    );
  });
}
