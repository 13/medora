import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/nre.dart';

void main() {
  group('isValid (NRE)', () {
    test('3 digits, a letter, 11 digits are valid', () {
      expect(Nre.isValid('041A00012345678'), isTrue);
      expect(Nre.isValid('041a0 0012345 678'), isTrue);
    });

    test('other lengths or shapes are not', () {
      expect(Nre.isValid('041A0001234567'), isFalse); // 14
      expect(Nre.isValid('041A000123456789'), isFalse); // 16
      expect(Nre.isValid('0410A0012345678'), isFalse); // letter in wrong spot
      expect(Nre.isValid('G00001234567'), isFalse); // an NRBE, not an NRE
    });
  });

  group('isNrbe (white electronic prescription number)', () {
    test('a letter followed by 11 digits is valid', () {
      expect(Nre.isNrbe('G00001234567'), isTrue);
      expect(Nre.isNrbe('g0000 1234567'), isTrue);
    });

    test('other lengths or shapes are not', () {
      expect(Nre.isNrbe('G0000123456'), isFalse); // 11
      expect(Nre.isNrbe('G000012345678'), isFalse); // 13
      expect(Nre.isNrbe('0400001234567'), isFalse); // no leading letter
      expect(Nre.isNrbe('041A00012345678'), isFalse); // an NRE, not an NRBE
    });
  });

  group('isPin', () {
    test('5 letters or digits are valid', () {
      expect(Nre.isPin('7XQ2K'), isTrue);
      expect(Nre.isPin('7xq2k'), isTrue);
    });

    test('other lengths or symbols are not', () {
      expect(Nre.isPin('7XQ2'), isFalse);
      expect(Nre.isPin('7XQ2K5'), isFalse);
      expect(Nre.isPin('7XQ-K'), isFalse);
    });
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(Nre.normalize(' 041a0 0012345 678 '), '041A00012345678');
  });

  group('split', () {
    test('the first 5 and last 10 characters of a valid NRE', () {
      expect(Nre.split('041A00012345678'), ('041A0', '0012345678'));
    });

    test('normalizes before splitting', () {
      expect(Nre.split('041a0 0012345 678'), ('041A0', '0012345678'));
    });

    test('null unless the NRE is valid', () {
      expect(Nre.split('G00001234567'), isNull);
      expect(Nre.split('too short'), isNull);
    });
  });
}
