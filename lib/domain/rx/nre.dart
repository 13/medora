/// Medora - Prescription numbers printed on an Italian prescription.
///
/// Two shapes, told apart by the prescription kind (spec §11, calibrated on
/// real South Tyrol prescriptions):
/// - SSN / referral: the 15-character NRE (numero di ricetta elettronica),
///   printed on the paper as two barcodes: the first 5 characters, then the
///   last 10 digits.
/// - white / white-repeatable: the 12-character NRBE (numero ricetta bianca
///   elettronica), an electronic white prescription only (a paper one has
///   none), together with a 5-character PIN printed under its barcode.
library;

abstract final class Nre {
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

  static final _nreShape = RegExp(r'^[0-9]{3}[A-Z][0-9]{11}$');
  static final _nrbeShape = RegExp(r'^[A-Z][0-9]{11}$');
  static final _pinShape = RegExp(r'^[A-Z0-9]{5}$');

  /// The 15-character SSN/referral NRE: 3 digits, a region letter, 11
  /// digits.
  static bool isValid(String raw) => _nreShape.hasMatch(normalize(raw));

  /// The 12-character white electronic prescription number (NRBE): a
  /// letter followed by 11 digits.
  static bool isNrbe(String raw) => _nrbeShape.hasMatch(normalize(raw));

  /// The 5-character PIN printed under an NRBE barcode.
  static bool isPin(String raw) => _pinShape.hasMatch(normalize(raw));

  /// The two barcodes printed on the SSN paper: the first 5 and the last 10
  /// characters of [nre]. Null unless [isValid].
  static (String, String)? split(String nre) {
    final normalized = normalize(nre);
    if (!isValid(normalized)) return null;
    return (normalized.substring(0, 5), normalized.substring(5));
  }
}
