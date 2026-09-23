/// Medora - Italian tax code (codice fiscale) of a person.
///
/// The pharmacy reads it with the prescription number, so a typo means a
/// wasted trip: the check character catches nearly every one.
library;

abstract final class TaxCode {
  /// Upper-case, whitespace removed: how the code is stored and compared.
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

  /// Letters for the name parts, digits (or their omocodia letters
  /// LMNPQRSTUV) for year, day and municipality number.
  static final _shape = RegExp(
    r'^[A-Z]{6}[0-9LMNPQRSTUV]{2}[ABCDEHLMPRST][0-9LMNPQRSTUV]{2}'
    r'[A-Z][0-9LMNPQRSTUV]{3}[A-Z]$',
  );

  static bool isValid(String raw) {
    final code = normalize(raw);
    if (!_shape.hasMatch(code)) return false;
    return checkCharacter(code.substring(0, 15)) == code[15];
  }

  /// The check character of the first fifteen characters [head].
  ///
  /// [head] must be exactly 15 characters from the codice fiscale alphabet
  /// (`A`-`Z`, `0`-`9`); anything else is a caller bug, so this throws
  /// rather than crashing on a null-checked map lookup.
  static String checkCharacter(String head) {
    if (head.length != 15) {
      throw ArgumentError.value(head, 'head', 'must be exactly 15 characters');
    }
    var sum = 0;
    for (var i = 0; i < 15; i++) {
      final c = head[i];
      final oddValue = _odd[c];
      if (oddValue == null) {
        throw ArgumentError.value(
          head,
          'head',
          'character "$c" at position $i is not in the codice fiscale '
              'alphabet (A-Z, 0-9)',
        );
      }
      // Positions are counted from 1, so index 0 is an odd position.
      sum += i.isEven ? oddValue : _even(c);
    }
    return String.fromCharCode(0x41 + sum % 26);
  }

  static int _even(String c) {
    final unit = c.codeUnitAt(0);
    return unit <= 0x39 ? unit - 0x30 : unit - 0x41;
  }

  static const _odd = {
    '0': 1, '1': 0, '2': 5, '3': 7, '4': 9, '5': 13, '6': 15, '7': 17, //
    '8': 19, '9': 21, 'A': 1, 'B': 0, 'C': 5, 'D': 7, 'E': 9, 'F': 13, //
    'G': 15, 'H': 17, 'I': 19, 'J': 21, 'K': 2, 'L': 4, 'M': 18, 'N': 20,
    'O': 11, 'P': 3, 'Q': 6, 'R': 8, 'S': 12, 'T': 14, 'U': 16, 'V': 10,
    'W': 22, 'X': 25, 'Y': 24, 'Z': 23,
  };
}
