/// Medora - the text-region second pass of the photo scanner
///
/// A package photographed from a distance leaves the label small in a large
/// frame, where ML Kit garbles text and misses the barcode. When the first
/// pass on the whole photo is incomplete ([needsRegionPass]) the scanner
/// recognises again on a crop around the text it found ([textRegionCrop])
/// and maps the results back to photo pixels ([offsetOcrLines],
/// [offsetCandidates]). Pure Dart, unit-tested directly.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:medora/services/code_candidates.dart';

/// Margin added on each side of the text region, as a fraction of its size.
const double regionMarginFraction = 0.08;

/// The largest region worth a second pass, as a fraction of the image area.
const double regionMaxAreaFraction = 0.60;

/// The crop for the second pass, in whole image pixels: the union of
/// [boxes] (OCR line and barcode boxes; empty boxes ignored) expanded by
/// [regionMarginFraction] of its width and height on each side and clamped
/// to [imageSize]. Null when there is no box or the crop covers more than
/// [regionMaxAreaFraction] of the image (too little to gain).
Rect? textRegionCrop(Iterable<Rect> boxes, Size imageSize) {
  if (imageSize.isEmpty) return null;
  Rect? union;
  for (final box in boxes) {
    if (box.width <= 0 || box.height <= 0) continue;
    union = union == null ? box : union.expandToInclude(box);
  }
  if (union == null) return null;
  final dx = union.width * regionMarginFraction;
  final dy = union.height * regionMarginFraction;
  final left = math.max(0, (union.left - dx).floor()).toDouble();
  final top = math.max(0, (union.top - dy).floor()).toDouble();
  final right = math.min(imageSize.width, (union.right + dx).ceilToDouble());
  final bottom = math.min(imageSize.height, (union.bottom + dy).ceilToDouble());
  if (right <= left || bottom <= top) return null;
  final crop = Rect.fromLTRB(left, top, right, bottom);
  final imageArea = imageSize.width * imageSize.height;
  if (crop.width * crop.height > regionMaxAreaFraction * imageArea) {
    return null;
  }
  return crop;
}

/// Whether the first pass left something to find: no barcode decoded, no
/// candidate at all, or a supplement / AIC label in [lines] without a
/// candidate of that kind in [candidates].
bool needsRegionPass({
  required List<OcrLine> lines,
  required List<CodeCandidate> barcodes,
  required List<CodeCandidate> candidates,
}) {
  if (barcodes.isEmpty || candidates.isEmpty) return true;
  return codeLabelKinds(
    lines,
  ).any((kind) => !candidates.any((c) => c.kind == kind));
}

/// [lines] with line and element boxes moved by [offset] (crop to photo
/// pixels).
List<OcrLine> offsetOcrLines(List<OcrLine> lines, Offset offset) => [
  for (final line in lines)
    OcrLine(line.text, line.box.shift(offset), [
      for (final element in line.elements)
        OcrElement(element.text, element.box.shift(offset)),
    ]),
];

/// [candidates] with boxes moved by [offset] (crop to photo pixels).
List<CodeCandidate> offsetCandidates(
  List<CodeCandidate> candidates,
  Offset offset,
) => [
  for (final c in candidates)
    CodeCandidate(
      code: c.code,
      kind: c.kind,
      sourceText: c.sourceText,
      box: c.box.shift(offset),
      alternatives: c.alternatives,
    ),
];
