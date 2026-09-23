/// Medora - Electronic prescription number (NRE, numero di ricetta
/// elettronica).
///
/// Only the shape is checked: the regional prefix varies and a wrong
/// guess about it must never block saving a real prescription.
library;

abstract final class Nre {
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

  static final _shape = RegExp(r'^[0-9A-Z]{15}$');

  static bool isValid(String raw) => _shape.hasMatch(normalize(raw));
}
