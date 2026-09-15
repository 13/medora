import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:medora/services/barcode_adapter.dart';
import 'package:medora/services/code_candidates.dart';

void main() {
  const box = Rect.fromLTWH(10, 20, 300, 80);

  test('EAN-13 and EAN-8 become EAN candidates with the barcode box', () {
    final ean13 = barcodeCandidate(BarcodeFormat.ean13, '8057737141836', box)!;
    expect(ean13.kind, CodeKind.ean);
    expect(ean13.code, '8057737141836');
    expect(ean13.box, box);

    final ean8 = barcodeCandidate(BarcodeFormat.ean8, '96385074', box)!;
    expect(ean8.kind, CodeKind.ean);
    expect(ean8.code, '96385074');
  });

  test('Code 39 / Code 128 "A" + 9 digits becomes an AIC candidate', () {
    for (final format in [BarcodeFormat.code39, BarcodeFormat.code128]) {
      final c = barcodeCandidate(format, 'A023834118', box)!;
      expect(c.kind, CodeKind.aic, reason: format.name);
      expect(c.code, '023834118');
      expect(c.sourceText, 'A023834118');
    }
  });

  test('other values become "other" candidates without separators', () {
    final lot = barcodeCandidate(BarcodeFormat.code128, 'LOT-4R5T21', box)!;
    expect(lot.kind, CodeKind.other);
    expect(lot.code, 'LOT4R5T21');

    final shortAic = barcodeCandidate(BarcodeFormat.code39, 'A02383411', box)!;
    expect(shortAic.kind, CodeKind.other);

    final matrix = barcodeCandidate(
      BarcodeFormat.dataMatrix,
      'A023834118',
      box,
    )!;
    expect(matrix.kind, CodeKind.other);
  });

  test('an EAN with a bad checksum is never an EAN candidate', () {
    final bad = barcodeCandidate(BarcodeFormat.ean13, '8057737141837', box)!;
    expect(bad.kind, CodeKind.other);
    expect(bad.code, '8057737141837');

    expect(barcodeCandidate(BarcodeFormat.ean8, '--', box), isNull);
  });

  test('merged with OCR lines, a barcode AIC replaces the OCR box', () {
    final candidates = findCodeCandidates(
      const [OcrLine('AIC A023834118', Rect.fromLTWH(0, 500, 100, 20))],
      barcodes: [barcodeCandidate(BarcodeFormat.code39, 'A023834118', box)!],
    );
    expect(candidates, hasLength(1));
    expect(candidates.single.kind, CodeKind.aic);
    expect(candidates.single.box, box);
    expect(candidates.single.sourceText, 'AIC A023834118');
  });

  test('empty values are dropped', () {
    expect(barcodeCandidate(BarcodeFormat.ean13, null, box), isNull);
    expect(barcodeCandidate(BarcodeFormat.code128, '  ', box), isNull);
    expect(barcodeCandidate(BarcodeFormat.code128, '--', box), isNull);
  });

  test('merged with OCR lines, a barcode EAN replaces the OCR box', () {
    final candidates = findCodeCandidates(
      const [OcrLine('8057737141836', Rect.fromLTWH(0, 500, 100, 20))],
      barcodes: [barcodeCandidate(BarcodeFormat.ean13, '8057737141836', box)!],
    );
    expect(candidates, hasLength(1));
    expect(candidates.single.box, box);
  });
}
