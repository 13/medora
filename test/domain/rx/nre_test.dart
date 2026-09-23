import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/nre.dart';

void main() {
  test('15 alphanumeric characters are valid', () {
    expect(Nre.isValid('0410A1234567890'), isTrue);
    expect(Nre.isValid('0410a 12345 67890'), isTrue);
  });

  test('other lengths or symbols are not', () {
    expect(Nre.isValid('0410A123456789'), isFalse);
    expect(Nre.isValid('0410A12345678901'), isFalse);
    expect(Nre.isValid('0410A-234567890'), isFalse);
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(Nre.normalize(' 0410a 12345 67890 '), '0410A1234567890');
  });
}
