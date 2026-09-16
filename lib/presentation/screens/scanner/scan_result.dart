/// Medora - what the scanner returns in return-only mode
///
/// Screens that push `AppRoutes.scannerReturnOnly` receive the chosen code
/// together with what it most likely is, so they can look it up in the
/// right place (AIFA for AIC codes, the food-supplement register for
/// supplement codes) or just keep it (EAN and other numbers). Supplement
/// and AIC codes carry the candidate's alternative readings, tried in order
/// when the code itself is not found (in the register or in AIFA); a match
/// found only through an alternative is used after the user confirms it.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/services/code_candidates.dart';

@immutable
class ScanResult {
  const ScanResult(
    this.code,
    this.kind, {
    this.alternatives = const [],
    this.ean,
  });

  final String code;
  final CodeKind kind;

  /// See `CodeCandidate.alternatives`.
  final List<String> alternatives;

  /// The EAN barcode the same photo carried next to [code], when [code] is
  /// a label code rather than the EAN itself. Remembered on the medication
  /// so a later scan of either finds it.
  final String? ean;

  @override
  bool operator ==(Object other) =>
      other is ScanResult &&
      other.code == code &&
      other.kind == kind &&
      other.ean == ean &&
      listEquals(other.alternatives, alternatives);

  @override
  int get hashCode =>
      Object.hash(code, kind, ean, Object.hashAll(alternatives));

  @override
  String toString() =>
      'ScanResult(${kind.name} $code${ean == null ? '' : ' ean $ean'})';
}
