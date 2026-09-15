/// Medora - ML Kit barcode scanning → code candidates
///
/// The only place that maps `google_mlkit_barcode_scanning` results to
/// [CodeCandidate]s: valid EAN-13 / EAN-8 become EAN candidates, a Code 39 /
/// Code 128 value `A` + 9 digits (the medicine "bollino") an AIC candidate,
/// anything else an "other" candidate.
library;

import 'dart:ui' show Rect;

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/scan_debug.dart';

/// The formats the scanner decodes on a package photo.
const scanBarcodeFormats = [
  BarcodeFormat.ean13,
  BarcodeFormat.ean8,
  BarcodeFormat.code39,
  BarcodeFormat.code128,
  BarcodeFormat.dataMatrix,
];

final _aicBollino = RegExp(r'^A[0-9]{9}$');
final _nonAlphanumeric = RegExp(r'[^A-Za-z0-9]');

/// Candidates for every decoded barcode with a usable value.
List<CodeCandidate> barcodeCandidatesFrom(List<Barcode> barcodes) => [
  for (final b in barcodes)
    ?barcodeCandidate(b.format, b.rawValue ?? b.displayValue, b.boundingBox),
];

/// One `[scan] barcode:` entry per decoded barcode (see `scan_debug.dart`),
/// including values that map to no candidate.
List<String> describeBarcodes(List<Barcode> barcodes) => [
  for (final b in barcodes)
    '[scan] barcode: ${b.format.name} ${b.rawValue ?? '<null raw>'} '
        '(display ${b.displayValue}) @ ${describeRect(b.boundingBox)}',
];

/// Maps one decoded barcode; null when it carries no usable value.
CodeCandidate? barcodeCandidate(BarcodeFormat format, String? value, Rect box) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (format == BarcodeFormat.ean13 || format == BarcodeFormat.ean8) {
    // An EAN with a bad checksum is never an EAN candidate.
    final ean = CodeCandidate.eanFromBarcode(raw, box);
    if (ean != null) return ean;
  }
  switch (format) {
    case BarcodeFormat.code39 || BarcodeFormat.code128
        when _aicBollino.hasMatch(raw.toUpperCase()):
      return CodeCandidate(
        code: BarcodeLookupDatasource.cleanCode(raw),
        kind: CodeKind.aic,
        sourceText: raw,
        box: box,
      );
    default:
      final code = raw.replaceAll(_nonAlphanumeric, '');
      if (code.isEmpty) return null;
      return CodeCandidate(
        code: code,
        kind: CodeKind.other,
        sourceText: raw,
        box: box,
      );
  }
}
