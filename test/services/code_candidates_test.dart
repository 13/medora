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
      // A 6-digit AIC (group code) needs an AIC label.
      final result = findCodeCandidates([
        _line('AIC 034567', 0),
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

    test('labelled codes shorter than 6 digits are supplements', () {
      for (final (text, code) in [
        ('COD MINSAN: 54321', '54321'),
        ('Cod. Min. 968', '968'),
        ('Notifica n. 1054', '1054'),
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.supplement).map((c) => c.code), [
          code,
        ], reason: text);
      }
    });

    test('a short code on the line below the label is a supplement', () {
      final result = findCodeCandidates([
        _line('COD. MIN. SAN.', 0),
        _line('54321', 45),
      ]);
      expect(_ofKind(result, CodeKind.supplement).map((c) => c.code), [
        '54321',
      ]);
    });

    test('quantities and dates after a label are not supplements', () {
      for (final text in [
        'COD MINSAN: 15mg',
        'COD MINSAN: 150mg',
        'COD MINSAN: 500 mg',
        'COD MINSAN: 100g',
        'COD MINSAN: 250 ml',
        'COD MINSAN: 120 kcal',
        'COD MINSAN: 100%',
        'COD MINSAN: 1.500',
        'COD MINSAN: 12/2027',
        'COD MINSAN: 2027/12',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.supplement), isEmpty, reason: text);
      }
    });

    test('unlabelled numbers shorter than 6 digits are not supplements', () {
      final result = findCodeCandidates([_line('Lotto 54321', 0)]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
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

    test('a number two lines after the label is not a supplement', () {
      // Unlabelled 6-digit runs are "other" (AIC codes are 9 digits).
      final result = findCodeCandidates([
        _line('COD MINSAN', 0),
        _line('Integratore alimentare', 50),
        _line('107018', 100),
      ]);
      expect(result.single.kind, CodeKind.other);
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

  group('findCodeCandidates: device OCR variants', () {
    String describe(List<CodeCandidate> list) =>
        list.map((c) => '${c.kind.name}:${c.code}').join(' ');

    test('an EAN read as 1 + 12 digits is an EAN', () {
      final result = findCodeCandidates([_line('8 057737141836', 0)]);
      expect(describe(result), 'ean:8057737141836');
    });

    test('an EAN read as 12 + 1 digits is an EAN', () {
      final result = findCodeCandidates([_line('805773714183 6', 0)]);
      expect(describe(result), 'ean:8057737141836');
    });

    test('a 1 + 12 run with a failed checksum keeps all 13 digits', () {
      final result = findCodeCandidates([_line('8 057737141837', 0)]);
      expect(describe(result), 'other:8057737141837');
    });

    test('label OCR variants still find the supplement code', () {
      for (final text in [
        'COD MINSAN.107018',
        'CODMINSAN 107018',
        'CODMINSAN:107018',
        'C0D MINSAN: 107018',
        'COD MlNSAN: 107018',
        'COD M1NSAN: 107018',
        'MINSAN 107018',
        'COD. MIN. SAN.: 107018',
        'COD MINSAN :: 107018',
        'cod minsan 107018',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'supplement:107018', reason: text);
      }
    });

    test('the code in another block on the same row is a supplement', () {
      // ML Kit order: the number's block comes first, other text between.
      final result = findCodeCandidates([
        const OcrLine('107018', Rect.fromLTWH(260, 102, 120, 36)),
        const OcrLine('Integratore alimentare', Rect.fromLTWH(0, 0, 400, 40)),
        const OcrLine('COD MINSAN:', Rect.fromLTWH(0, 100, 240, 40)),
        const OcrLine('8 057737141836', Rect.fromLTWH(0, 300, 400, 40)),
      ]);
      expect(describe(result), 'supplement:107018 ean:8057737141836');
    });

    test('a number on the same row left of the label is not a supplement', () {
      final result = findCodeCandidates([
        const OcrLine('123456', Rect.fromLTWH(0, 100, 120, 40)),
        const OcrLine('COD MINSAN:', Rect.fromLTWH(200, 100, 240, 40)),
      ]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
    });

    test('a number on another row in a later block is not a supplement', () {
      final result = findCodeCandidates([
        const OcrLine('COD MINSAN:', Rect.fromLTWH(0, 100, 240, 40)),
        const OcrLine('Lotto', Rect.fromLTWH(0, 400, 240, 40)),
        const OcrLine('123456', Rect.fromLTWH(260, 180, 120, 40)),
      ]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
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

  group('findCodeCandidates: AIC length', () {
    String describe(List<CodeCandidate> list) =>
        list.map((c) => '${c.kind.name}:${c.code}').join(' ');

    test('unlabelled 6-8 digit runs are "other", not AIC', () {
      for (final (text, code) in [
        ('057737', '057737'),
        ('Lotto 141836', '141836'),
        ('1234567', '1234567'),
        ('B1234567', 'B1234567'),
        ('12345678 x', '12345678'),
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'other:$code', reason: text);
      }
    });

    test('unlabelled 9-digit runs, with or without a letter, are AIC', () {
      expect(
        describe(findCodeCandidates([_line('034567891', 0)])),
        'aic:034567891',
      );
      expect(
        describe(findCodeCandidates([_line('A034567891', 0)])),
        'aic:034567891',
      );
    });

    test('an AIC label keeps 6-8 digit codes as AIC', () {
      for (final (text, code) in [
        ('AIC 034567', '034567'),
        ('A.I.C. n. 03456789', '03456789'),
        ('Cod. AIC: 0345678', '0345678'),
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'aic:$code', reason: text);
      }
    });
  });

  group('findCodeCandidates: digit lookalikes after a label', () {
    String describe(List<CodeCandidate> list) =>
        list.map((c) => '${c.kind.name}:${c.code}').join(' ');

    test('COD MINSAN: 10T018 is supplement 107018', () {
      final result = findCodeCandidates([_line('COD MINSAN: 10T018', 0)]);
      expect(describe(result), 'supplement:107018');
    });

    test('COD MINSAN: 1O7O18 is supplement 107018', () {
      final result = findCodeCandidates([_line('COD MINSAN: 1O7O18', 0)]);
      expect(describe(result), 'supplement:107018');
    });

    test('the repaired code keeps its element box and source text', () {
      const box = Rect.fromLTWH(221, 254, 200, 64);
      final result = findCodeCandidates([
        const OcrLine('COD MINSAN: 10T018', Rect.fromLTWH(0, 254, 565, 64), [
          OcrElement('COD', Rect.fromLTWH(0, 254, 80, 64)),
          OcrElement('MINSAN:', Rect.fromLTWH(90, 254, 120, 64)),
          OcrElement('10T018', box),
        ]),
      ]);
      expect(describe(result), 'supplement:107018');
      expect(result.single.box, box);
      expect(result.single.sourceText, 'COD MINSAN: 10T018');
    });

    test('each lookalike maps to its digit', () {
      for (final (text, code) in [
        ('COD MINSAN: 1Q7D18', '107018'),
        ('COD MINSAN: 12I4l6', '121416'),
        ('COD MINSAN: 1|3!5i', '113151'),
        ('COD MINSAN: 1Z3z56', '123256'),
        ('COD MINSAN: 1S3s56', '153556'),
        ('COD MINSAN: 1G3b56', '163656'),
        ('COD MINSAN: 1t3?56', '173756'),
        ('COD MINSAN: 1B3g5q', '183959'),
        ('COD MINSAN: 10T018.', '107018'),
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'supplement:$code', reason: text);
      }
    });

    test('an AIC label repairs its code too', () {
      final result = findCodeCandidates([_line('AIC n. O3456789l', 0)]);
      expect(describe(result), 'aic:034567891');
    });

    test('words and mostly-letter tokens are not repaired', () {
      for (final text in [
        'COD MINSAN: TOTALE',
        'COD MINSAN: BIOS',
        'COD MINSAN: 1OTS',
        'COD MINSAN: 10TOSB',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.supplement), isEmpty, reason: text);
      }
    });

    test('quantities after a label stay quantities', () {
      for (final text in [
        'COD MINSAN: 15mg',
        'COD MINSAN: 150mg',
        'COD MINSAN: 100g',
        'COD MINSAN: 250ml',
        'COD MINSAN: 1.500',
        'COD MINSAN: 12/2027',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.supplement), isEmpty, reason: text);
      }
    });

    test('an ambiguous lookalike offers the other digit as alternative', () {
      final result = findCodeCandidates([_line('COD MINSAN: T07018', 0)]);
      expect(describe(result), 'supplement:707018');
      expect(result.single.alternatives, contains('107018'));
      expect(result.single.alternatives, isNot(contains('707018')));
    });

    test('a token without lookalikes has no alternatives', () {
      final result = findCodeCandidates([_line('COD MINSAN: 107018', 0)]);
      expect(describe(result), 'supplement:107018');
      expect(result.single.alternatives, isEmpty);
    });

    test('unambiguous lookalikes have no alternatives', () {
      final result = findCodeCandidates([_line('COD MINSAN: 1O7O18', 0)]);
      expect(describe(result), 'supplement:107018');
      expect(result.single.alternatives, isEmpty);
    });

    test('each ambiguous lookalike has its second digit', () {
      for (final (text, code, alternative) in [
        ('COD MINSAN: 10t018', '107018', '101018'),
        ('COD MINSAN: 10?018', '107018', '101018'),
        ('COD MINSAN: 70l018', '701018', '707018'),
        ('COD MINSAN: 70I018', '701018', '707018'),
        ('COD MINSAN: 70|018', '701018', '707018'),
        ('COD MINSAN: 70i018', '701018', '707018'),
        ('COD MINSAN: 70!018', '701018', '707018'),
        ('COD MINSAN: 10B018', '108018', '103018'),
        ('COD MINSAN: 10G018', '106018', '100018'),
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'supplement:$code', reason: text);
        expect(result.single.alternatives, [alternative], reason: text);
      }
    });

    test('alternatives combine, fewest changes first, unique', () {
      final result = findCodeCandidates([_line('COD MINSAN: T0B018', 0)]);
      expect(describe(result), 'supplement:708018');
      expect(result.single.alternatives, ['108018', '703018', '103018']);
    });

    test('alternatives are capped', () {
      final result = findCodeCandidates([_line('COD MINSAN: TlBG12345', 0)]);
      expect(result.single.code, '718612345');
      final alternatives = result.single.alternatives;
      expect(alternatives, hasLength(15)); // 2^4 - 1: under the cap
      expect(alternatives.toSet(), hasLength(15));
      expect(alternatives.first, '118612345');
      expect(alternatives.last, '173012345');
      expect(alternatives.length, lessThanOrEqualTo(maxCodeAlternatives));
    });

    test('an AIC code keeps its alternatives through the ranking', () {
      final result = findCodeCandidates([_line('AIC n. T34567891', 0)]);
      expect(describe(result), 'aic:734567891');
      expect(result.single.alternatives, ['134567891']);
    });

    test('only the code after an AIC label is repaired and labelled', () {
      // Review M4: the second token was repaired to a labelled 6-digit AIC.
      final result = findCodeCandidates([_line('AIC 012345678 S12345', 0)]);
      expect(_ofKind(result, CodeKind.aic).map((c) => c.code), ['012345678']);
      expect(result.map((c) => c.code), isNot(contains('512345')));
      expect(
        describe(findCodeCandidates([_line('AIC 012345678 123456', 0)])),
        isNot(contains('aic:123456')),
      );
    });

    test('a punctuated 4+4 digit price is not an EAN-8', () {
      // Review M4: 12345670 has a valid EAN-8 checksum.
      final result = findCodeCandidates([_line('Prezzo 1234.5670', 0)]);
      expect(_ofKind(result, CodeKind.ean), isEmpty);
      expect(result.map((c) => c.code), isNot(contains('12345670')));
      expect(
        describe(findCodeCandidates([_line('1234 5670', 0)])),
        'ean:12345670',
      );
    });

    test('lookalikes without a label are not repaired', () {
      final result = findCodeCandidates([_line('Lotto 10T018', 0)]);
      expect(describe(result), 'other:10T018');
    });
  });

  group('findCodeCandidates: EAN digit groups with punctuation', () {
    String describe(List<CodeCandidate> list) =>
        list.map((c) => '${c.kind.name}:${c.code}').join(' ');

    test('8 "057737"141836 is one EAN and nothing else', () {
      final result = findCodeCandidates([_line('8 "057737"141836', 0)]);
      expect(describe(result), 'ean:8057737141836');
    });

    test('quotes, apostrophes, backticks, commas and dots join groups', () {
      for (final text in [
        "8 '057737'141836",
        '8 `057737` 141836',
        '8,057737,141836',
        '8.057737.141836',
        '8 \u201C057737\u201D141836',
        '"8057737"141836',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(describe(result), 'ean:8057737141836', reason: text);
      }
    });

    test('punctuation-joined groups with a bad checksum are no EAN', () {
      final result = findCodeCandidates([_line('8 "057737"141837', 0)]);
      expect(_ofKind(result, CodeKind.ean), isEmpty);
      expect(result.map((c) => c.code), isNot(contains('8057737141837')));
    });

    test('decimals and dates are not joined', () {
      for (final text in ['1.500', '12,5 mg', '03.2027']) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.ean), isEmpty, reason: text);
      }
    });

    test('an EAN sub-run overlapping the EAN line is dropped', () {
      final result = findCodeCandidates([
        const OcrLine('8 057737141836', Rect.fromLTWH(831, 2008, 1201, 183)),
        const OcrLine('057737', Rect.fromLTWH(1000, 2050, 300, 80)),
        const OcrLine('141836 x', Rect.fromLTWH(1400, 2050, 300, 80)),
      ]);
      expect(describe(result), 'ean:8057737141836');
    });

    test('an EAN sub-run overlapping the barcode box is dropped', () {
      const barcodeBox = Rect.fromLTWH(841, 1842, 1116, 252);
      final result = findCodeCandidates(
        [const OcrLine('141836', Rect.fromLTWH(1500, 2000, 300, 80))],
        barcodes: [CodeCandidate.eanFromBarcode('8057737141836', barcodeBox)!],
      );
      expect(describe(result), 'ean:8057737141836');
    });

    test('an EAN sub-run elsewhere on the pack is kept', () {
      final result = findCodeCandidates([
        const OcrLine('8 057737141836', Rect.fromLTWH(831, 2008, 1201, 183)),
        const OcrLine('Lotto 057737', Rect.fromLTWH(0, 100, 300, 80)),
      ]);
      expect(describe(result), 'ean:8057737141836 other:057737');
    });

    test('an EAN after a number and punctuation is still an EAN', () {
      // Review I2: `N. ` / `N, ` before the EAN joined the groups into a run
      // that is no EAN shape, so the EAN came out as "other".
      for (final text in [
        'SCAD. 2026. 8057737141836',
        'Lotto 24031, 8057737141836',
        'Lotto 2401. 8057737141836',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.ean).map((c) => c.code), [
          '8057737141836',
        ], reason: text);
        expect(
          result.map((c) => c.code),
          isNot(contains(contains('20268057737141836'))),
          reason: text,
        );
      }
    });

    test('a whole EAN-13 next to other numbers is still an EAN', () {
      for (final text in [
        'EAN 8057737141836 20 g',
        'COD MINSAN: 107018 8057737141836',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.ean).map((c) => c.code), [
          '8057737141836',
        ], reason: text);
        expect(_ofKind(result, CodeKind.other), isEmpty, reason: text);
      }
      expect(
        describe(
          findCodeCandidates([_line('COD MINSAN: 107018 8057737141836', 0)]),
        ),
        'supplement:107018 ean:8057737141836',
      );
    });

    test('a spaced EAN after a number and a dot is an EAN', () {
      final result = findCodeCandidates([
        _line('SCAD. 2026. 8 057737 141836', 0),
      ]);
      expect(_ofKind(result, CodeKind.ean).map((c) => c.code), [
        '8057737141836',
      ]);
    });
  });

  test('codeLabelKinds names the labels present', () {
    Set<CodeKind> kinds(List<String> texts) =>
        codeLabelKinds([for (final t in texts) _line(t, 0)]);
    expect(kinds(['COD MINSAN: @']), {CodeKind.supplement});
    expect(kinds(['A.I.C. n.', 'Notifica n. 1054']), {
      CodeKind.aic,
      CodeKind.supplement,
    });
    expect(kinds(['Integratore alimentare', '8 057737141836']), isEmpty);
  });
}
