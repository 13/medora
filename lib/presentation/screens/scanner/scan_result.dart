/// Medora - what the scanner returns in return-only mode
///
/// Screens that push `AppRoutes.scannerReturnOnly` receive the chosen code
/// together with what it most likely is, so they can look it up in the
/// right place (AIFA for AIC codes, the food-supplement register for
/// supplement codes) or just keep it (EAN and other numbers).
library;

import 'package:flutter/foundation.dart';
import 'package:medora/services/code_candidates.dart';

@immutable
class ScanResult {
  const ScanResult(this.code, this.kind);

  final String code;
  final CodeKind kind;

  @override
  bool operator ==(Object other) =>
      other is ScanResult && other.code == code && other.kind == kind;

  @override
  int get hashCode => Object.hash(code, kind);

  @override
  String toString() => 'ScanResult(${kind.name} $code)';
}
