import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/code39.dart';

void main() {
  test('encodes start/stop and one character per 9 elements + gap', () {
    final bars = Code39.encode('A')!;
    // "*A*": 3 characters × (6 narrow + 3 wide = 6 + 9 = 15 modules) + 2 gaps.
    expect(bars.length, 3 * 15 + 2);
    // A character starts and ends with a bar.
    expect(bars.first, isTrue);
    expect(bars.last, isTrue);
  });

  test('A encodes as 100001001 (bar and space alternate, 1 = wide)', () {
    final bars = Code39.encode('A')!;
    // Skip "*" (15 modules) and its gap (1 module).
    final a = bars.sublist(16, 31);
    // A = 100001001 → bar W, sp N, bar N, sp N, bar N, sp W, bar N, sp N, bar W
    expect(a, [
      true, true, true, false, true, false, true, false, false, false, //
      true, false, true, true, true,
    ]);
  });

  test('digits and upper-case letters of an NRE and a tax code encode', () {
    expect(Code39.encode('0410A1234567890'), isNotNull);
    expect(Code39.encode('RSSMRA85T10A562S'), isNotNull);
  });

  test('lower case and unsupported symbols do not', () {
    expect(Code39.encode('a'), isNull);
    expect(Code39.encode('#'), isNull);
  });
}
