import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/code_candidates.dart';

OcrLine _line(String text, double top, {double left = 0}) =>
    OcrLine(text, Rect.fromLTWH(left, top, 400, 40));

List<CodeCandidate> _ofKind(List<CodeCandidate> list, CodeKind kind) =>
    list.where((c) => c.kind == kind).toList();

void main() {
  group('findCodeCandidates: AIC and other', () {
    test('A023834118 yields one AIC candidate with the element box', () {
      const elementBox = Rect.fromLTWH(120, 10, 180, 30);
      final result = findCodeCandidates([
        const OcrLine('AIC A023834118', Rect.fromLTWH(0, 0, 400, 50), [
          OcrElement('AIC', Rect.fromLTWH(0, 10, 100, 30)),
          OcrElement('A023834118', elementBox),
        ]),
      ]);
      expect(result, hasLength(1));
      expect(result.single.kind, CodeKind.aic);
      expect(result.single.code, '023834118');
      expect(result.single.box, elementBox);
      expect(result.single.sourceText, 'AIC A023834118');
    });

    test('without elements the box is the line box', () {
      final result = findCodeCandidates([_line('A023834118', 10)]);
      expect(result.single.box, const Rect.fromLTWH(0, 10, 400, 40));
    });

    test('mixed lines rank the AIC first and keep lot/EAN-like numbers', () {
      final result = findCodeCandidates([
        _line('Lotto 4R5T21', 0),
        _line('AIC n. 034567891', 50),
        _line('Scad. 03/2027', 100),
        _line('EAN 8001234567890', 150),
      ]);
      expect(result.first.kind, CodeKind.aic);
      expect(result.first.code, '034567891');
      expect(_ofKind(result, CodeKind.aic), hasLength(1));
      final others = _ofKind(result, CodeKind.other).map((c) => c.code);
      expect(others, containsAll(['4R5T21', '8001234567890']));
      expect(others, isNot(contains('034567891')));
      expect(result.map((c) => c.code).any((c) => c.contains('2027')), isFalse);
    });

    test('the same AIC on two lines is one candidate (first box)', () {
      final result = findCodeCandidates([
        _line('A023834118', 10),
        _line('023834118', 200),
      ]);
      expect(result, hasLength(1));
      expect(result.single.box.top, 10);
    });

    test('9-digit AIC ranks before 6-digit, then top and left', () {
      final result = findCodeCandidates([
        _line('034567', 0),
        _line('B023834118', 300, left: 50),
        _line('A012345678', 300, left: 10),
        _line('A098765432', 100),
      ]);
      expect(result.map((c) => c.code), [
        '098765432',
        '012345678',
        '023834118',
        '034567',
      ]);
    });

    test('empty input yields nothing', () {
      expect(findCodeCandidates(const []), isEmpty);
    });

    test('limit is respected', () {
      final lines = [
        for (var i = 0; i < 10; i++) _line('A0${i}0000000', i * 50.0),
      ];
      expect(findCodeCandidates(lines, limit: 3), hasLength(3));
    });
  });

  group('findCodeCandidates: supplements and EAN', () {
    test('the photographed supplement label', () {
      final result = findCodeCandidates([
        _line('Prodotto notificato al Ministero della Salute.', 0),
        _line('COD MINSAN: 107018', 50),
        _line('Avvertenze: non superare la dose giornaliera', 100),
        _line('8 057737 141836', 150),
      ]);
      final supplements = _ofKind(result, CodeKind.supplement);
      final eans = _ofKind(result, CodeKind.ean);
      expect(supplements.map((c) => c.code), ['107018']);
      expect(eans.map((c) => c.code), ['8057737141836']);
      expect(_ofKind(result, CodeKind.aic), isEmpty);
      expect(_ofKind(result, CodeKind.other), isEmpty);
    });

    test('label variants classify as supplement', () {
      for (final lines in [
        [_line('COD. MIN. SAN. 107018', 0)],
        [_line('Cod. Minsan 107018', 0)],
        [_line('codice ministeriale: 107018', 0)],
        [_line('Notifica n. 107018', 0)],
        [_line('COD. MIN. SAN.', 0), _line('107018', 50)],
      ]) {
        final result = findCodeCandidates(lines);
        expect(
          result.map((c) => '${c.kind.name}:${c.code}'),
          ['supplement:107018'],
          reason: lines.map((l) => l.text).join(' / '),
        );
      }
    });

    test('a number two lines after the label stays an AIC', () {
      final result = findCodeCandidates([
        _line('COD MINSAN', 0),
        _line('Integratore alimentare', 50),
        _line('107018', 100),
      ]);
      expect(result.single.kind, CodeKind.aic);
    });

    test('a letter-prefixed 9-digit code without a label stays AIC', () {
      final result = findCodeCandidates([_line('A023834118', 0)]);
      expect(result.single.kind, CodeKind.aic);
    });

    test('supplement code elsewhere on the pack is not also an AIC', () {
      final result = findCodeCandidates([
        _line('Minsan 107018', 0),
        _line('107018', 100),
      ]);
      expect(result.map((c) => '${c.kind.name}:${c.code}'), [
        'supplement:107018',
      ]);
    });

    test('an unspaced and a partly grouped EAN-13 are found', () {
      for (final text in ['8057737141836', '8057737 141836']) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(result.map((c) => '${c.kind.name}:${c.code}'), [
          'ean:8057737141836',
        ], reason: text);
      }
    });

    test('an invalid EAN-13 checksum is not an EAN', () {
      final result = findCodeCandidates([_line('8057737141837', 0)]);
      expect(_ofKind(result, CodeKind.ean), isEmpty);
      expect(_ofKind(result, CodeKind.aic), isEmpty);
      expect(result.map((c) => c.code), ['8057737141837']);
      expect(result.single.kind, CodeKind.other);
    });

    test('an EAN-8 validates', () {
      expect(isValidEan('96385074'), isTrue);
      expect(isValidEan('96385075'), isFalse);
      final result = findCodeCandidates([_line('9638 5074', 0)]);
      expect(result.map((c) => '${c.kind.name}:${c.code}'), ['ean:96385074']);
    });

    test('grouped EAN box spans its elements', () {
      final result = findCodeCandidates([
        const OcrLine('EAN 8 057737 141836', Rect.fromLTWH(0, 0, 500, 40), [
          OcrElement('EAN', Rect.fromLTWH(0, 0, 60, 40)),
          OcrElement('8', Rect.fromLTWH(70, 0, 20, 40)),
          OcrElement('057737', Rect.fromLTWH(100, 0, 150, 40)),
          OcrElement('141836', Rect.fromLTWH(260, 0, 150, 40)),
        ]),
      ]);
      expect(result.single.kind, CodeKind.ean);
      expect(result.single.box, const Rect.fromLTRB(70, 0, 410, 40));
    });

    test('eanFromBarcode dedupes with the OCR EAN and its box wins', () {
      const barcodeBox = Rect.fromLTWH(10, 500, 300, 120);
      final result = findCodeCandidates(
        [_line('8 057737 141836', 150)],
        barcodes: [CodeCandidate.eanFromBarcode('8057737141836', barcodeBox)!],
      );
      expect(result, hasLength(1));
      expect(result.single.kind, CodeKind.ean);
      expect(result.single.code, '8057737141836');
      expect(result.single.box, barcodeBox);
      expect(result.single.sourceText, '8 057737 141836');
    });

    test('a barcode without an OCR match is added', () {
      const box = Rect.fromLTWH(0, 0, 10, 10);
      final result = findCodeCandidates(
        [_line('A023834118', 0)],
        barcodes: [CodeCandidate.eanFromBarcode('96385074', box)!],
      );
      expect(result.map((c) => '${c.kind.name}:${c.code}'), [
        'aic:023834118',
        'ean:96385074',
      ]);
    });

    test('eanFromBarcode rejects values that are not a valid EAN', () {
      const box = Rect.fromLTWH(0, 0, 10, 10);
      expect(CodeCandidate.eanFromBarcode('8057737141837', box), isNull);
      expect(CodeCandidate.eanFromBarcode('12345', box), isNull);
      expect(CodeCandidate.eanFromBarcode('', box), isNull);
    });

    test('a barcode AIC dedupes with the OCR AIC and its box wins', () {
      const barcodeBox = Rect.fromLTWH(20, 600, 300, 90);
      final result = findCodeCandidates(
        [_line('AIC n. 023834118', 10)],
        barcodes: [
          const CodeCandidate(
            code: '023834118',
            kind: CodeKind.aic,
            sourceText: 'A023834118',
            box: barcodeBox,
          ),
        ],
      );
      expect(result, hasLength(1));
      expect(result.single.kind, CodeKind.aic);
      expect(result.single.box, barcodeBox);
      expect(result.single.sourceText, 'AIC n. 023834118');
    });
  });

  group('findCodeCandidates: review fixes', () {
    String describe(List<CodeCandidate> list) =>
        list.map((c) => '${c.kind.name}:${c.code}').join(' ');

    test('digits after an AIC do not join into a fake EAN', () {
      final result = findCodeCandidates([_line('A.I.C. 034567891 0009', 0)]);
      expect(_ofKind(result, CodeKind.aic).map((c) => c.code), ['034567891']);
      expect(_ofKind(result, CodeKind.ean), isEmpty);
    });

    test('digits after a supplement code do not join into a fake EAN', () {
      final result = findCodeCandidates([_line('COD MINSAN 107018 05', 0)]);
      expect(describe(result), 'supplement:107018');
    });

    test('a grouped EAN with a failed checksum is one "other"', () {
      final result = findCodeCandidates([_line('8 057737 141837', 0)]);
      expect(describe(result), 'other:8057737141837');
    });

    test('only groups printed like an EAN join', () {
      expect(
        describe(findCodeCandidates([_line('8 057737 141836 12', 0)])),
        isNot(contains('ean:')),
      );
      expect(
        describe(findCodeCandidates([_line('X8 057737 141836', 0)])),
        isNot(contains('ean:')),
      );
      expect(
        describe(findCodeCandidates([_line('8  057737  141836', 0)])),
        isNot(contains('ean:')),
      );
    });

    test('an unrelated line far below the label is not a supplement', () {
      final result = findCodeCandidates([
        _line('COD MINSAN', 0),
        _line('Lotto 123456', 600),
      ]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
    });

    test('a nearby overlapping line below the label is a supplement', () {
      final result = findCodeCandidates([
        _line('COD MINSAN', 0),
        _line('n. 107018', 45),
      ]);
      expect(describe(result), 'supplement:107018');
    });

    test('a nearby line that does not overlap the label is not', () {
      final result = findCodeCandidates([
        _line('COD MINSAN', 0),
        _line('n. 107018', 45, left: 900),
      ]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
    });

    test('only the first number after the label is a supplement', () {
      final result = findCodeCandidates([
        _line('COD MINSAN 107018 AIC 034567891', 0),
      ]);
      expect(describe(result), 'aic:034567891 supplement:107018');
    });
  });

  group('findCodeCandidates: ranking', () {
    test('ranking: aic, supplement, ean, other', () {
      final result = findCodeCandidates([
        _line('Lotto 4R5T21', 0),
        _line('8057737141836', 50),
        _line('COD MINSAN 107018', 100),
        _line('A023834118', 150),
      ]);
      expect(result.map((c) => c.kind), [
        CodeKind.aic,
        CodeKind.supplement,
        CodeKind.ean,
        CodeKind.other,
      ]);
    });
  });
}
