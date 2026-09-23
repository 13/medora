import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/tax_code.dart';

void main() {
  test('accepts valid codes and their normalised forms', () {
    expect(TaxCode.isValid('RSSMRA85T10A562S'), isTrue);
    expect(TaxCode.isValid('rssmra85t10a562s'), isTrue);
    expect(TaxCode.isValid(' RSS MRA 85T10 A562S '), isTrue);
    expect(TaxCode.isValid('MRTMTT25D09F205Z'), isTrue);
  });

  test('rejects a wrong check character', () {
    expect(TaxCode.isValid('RSSMRA85T10A562T'), isFalse);
  });

  test('rejects wrong length and alphabet', () {
    expect(TaxCode.isValid('RSSMRA85T10A562'), isFalse);
    expect(TaxCode.isValid('RSSMRA85T10A56!S'), isFalse);
    expect(TaxCode.isValid(''), isFalse);
  });

  test('accepts omocodia (digits replaced by LMNPQRSTUV)', () {
    // 85 -> RS in the year; check character recomputed for the new code.
    const omocode = 'RSSMRARST10A562S';
    final expected = TaxCode.checkCharacter(omocode.substring(0, 15));
    expect(TaxCode.isValid('${omocode.substring(0, 15)}$expected'), isTrue);
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(TaxCode.normalize(' rss mra85t10a562s\n'), 'RSSMRA85T10A562S');
  });
}
