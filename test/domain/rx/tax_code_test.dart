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
    // RSSMRA85T10A562S with the year digits '85' replaced by their
    // omocodia letters ('8'->'U', '5'->'R'): head 'RSSMRAURT10A562'.
    // Check letter hand-computed with the odd/even tables: 'B' (see the
    // fix-round report for the worked sum).
    expect(TaxCode.isValid('RSSMRAURT10A562B'), isTrue);
    expect(TaxCode.isValid('RSSMRAURT10A562A'), isFalse);
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(TaxCode.normalize(' rss mra85t10a562s\n'), 'RSSMRA85T10A562S');
  });

  test(
    'checkCharacter rejects a head that is not 15 normalised characters',
    () {
      expect(() => TaxCode.checkCharacter('TOOSHORT'), throwsArgumentError);
      expect(
        () => TaxCode.checkCharacter('RSSMRA85T10A56!'),
        throwsArgumentError,
      );
    },
  );
}
