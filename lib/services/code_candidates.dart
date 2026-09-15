/// Medora - code candidates found in a photographed package
///
/// Turns recognised OCR lines into ranked, tappable code candidates:
/// AIC codes (medicines), Ministry of Health supplement notification codes,
/// EAN barcodes and other number-like tokens (lot, batch). Pure Dart with no
/// ML Kit import, so it is unit-tested directly; see `ocr_adapter.dart` for
/// the mapping from ML Kit results.
library;

import 'dart:ui' show Rect;

import 'package:medora/data/datasources/barcode_lookup_datasource.dart';

/// One OCR word with its bounding box in image pixels.
class OcrElement {
  const OcrElement(this.text, this.box);

  final String text;
  final Rect box;
}

/// One OCR line with its bounding box in image pixels and its words.
class OcrLine {
  const OcrLine(this.text, this.box, [this.elements = const []]);

  final String text;
  final Rect box;
  final List<OcrElement> elements;
}

/// What a candidate code most likely is, in ranking order.
enum CodeKind { aic, supplement, ean, other }

class CodeCandidate {
  const CodeCandidate({
    required this.code,
    required this.kind,
    required this.sourceText,
    required this.box,
  });

  /// A candidate decoded by a barcode scanner rather than read by OCR.
  static CodeCandidate eanFromBarcode(String value, Rect box) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    return CodeCandidate(
      code: digits,
      kind: CodeKind.ean,
      sourceText: value,
      box: box,
    );
  }

  /// AIC / supplement / EAN: digits only; other: alphanumerics without spaces.
  final String code;
  final CodeKind kind;

  /// The OCR line the code came from.
  final String sourceText;

  /// Image-pixel rect: the element(s) containing the code, else the line.
  final Rect box;

  @override
  String toString() => 'CodeCandidate(${kind.name} $code @ $box)';
}

/// Ranks the codes found in [lines]: AIC codes first (9-digit before
/// shorter), then supplement codes, then EAN barcodes, then other
/// number-like tokens (>= 6 alphanumerics with >= 4 digits, e.g. lot/batch).
/// Within a kind candidates run top-to-bottom, then left-to-right.
/// Deduplicated by kind and code (first occurrence wins), at most [limit].
///
/// [barcodes] are EANs decoded by a barcode scanner
/// ([CodeCandidate.eanFromBarcode]); when OCR read the same EAN, the
/// barcode's box is used.
List<CodeCandidate> findCodeCandidates(
  List<OcrLine> lines, {
  List<CodeCandidate> barcodes = const [],
  int limit = 20,
}) {
  final found = <CodeCandidate>[];
  var labelPending = false;

  for (final line in lines) {
    final text = line.text;
    final elementSpans = _elementSpans(line);
    final claimed = <_Span>[];

    Rect boxFor(_Span span) {
      Rect? box;
      for (var i = 0; i < line.elements.length; i++) {
        final elementSpan = elementSpans[i];
        if (elementSpan == null || !elementSpan.overlaps(span)) continue;
        final elementBox = line.elements[i].box;
        box = box == null ? elementBox : box.expandToInclude(elementBox);
      }
      return box ?? line.box;
    }

    bool isClaimed(_Span span) => claimed.any((c) => c.overlaps(span));

    void add(String code, CodeKind kind, _Span span) {
      found.add(
        CodeCandidate(
          code: code,
          kind: kind,
          sourceText: text.trim(),
          box: boxFor(span),
        ),
      );
    }

    // EAN-13 / EAN-8, possibly printed in digit groups.
    for (final ean in _findEans(text)) {
      claimed.add(ean.span);
      add(ean.code, CodeKind.ean, ean.span);
    }

    // Supplement codes: a number on a labelled line, or on the line after.
    final labelHere = _supplementLabel.hasMatch(text.toUpperCase());
    var supplementFound = false;
    if (labelHere || labelPending) {
      for (final m in _digitRun.allMatches(text)) {
        final span = _Span(m.start, m.end);
        if (isClaimed(span)) continue;
        claimed.add(span);
        supplementFound = true;
        add(m[0]!, CodeKind.supplement, span);
      }
    }
    labelPending = labelHere && !supplementFound;

    // AIC codes: optional letter + 6-9 digits, not already claimed.
    for (final m in BarcodeLookupDatasource.aicPattern.allMatches(text)) {
      final span = _Span(m.start, m.end);
      if (isClaimed(span)) continue;
      final code = BarcodeLookupDatasource.cleanCode(m[0]!);
      if (code.length < 6) continue;
      claimed.add(span);
      add(code, CodeKind.aic, span);
    }

    // Other number-like tokens.
    for (final m in _token.allMatches(text)) {
      final token = m[0]!;
      if (token.length < 6) continue;
      if (_digit.allMatches(token).length < 4) continue;
      final span = _Span(m.start, m.end);
      if (isClaimed(span)) continue;
      add(token, CodeKind.other, span);
    }
  }

  // Merge barcode-decoded EANs: their box wins over the OCR one.
  for (final barcode in barcodes) {
    final index = found.indexWhere(
      (c) => c.kind == CodeKind.ean && c.code == barcode.code,
    );
    if (index < 0) {
      found.add(barcode);
    } else {
      found[index] = CodeCandidate(
        code: barcode.code,
        kind: CodeKind.ean,
        sourceText: found[index].sourceText,
        box: barcode.box,
      );
    }
  }

  Set<String> codesOf(CodeKind kind) => {
    for (final c in found)
      if (c.kind == kind) c.code,
  };
  final supplementCodes = codesOf(CodeKind.supplement);
  final eanCodes = codesOf(CodeKind.ean);
  final aicCodes = codesOf(CodeKind.aic)..removeAll(supplementCodes);

  final seen = <String>{};
  final kept = <CodeCandidate>[];
  for (final c in found) {
    if (c.kind == CodeKind.aic && supplementCodes.contains(c.code)) continue;
    if (c.kind == CodeKind.other &&
        (supplementCodes.contains(c.code) ||
            eanCodes.contains(c.code) ||
            aicCodes.any((aic) => aic.contains(c.code)))) {
      continue;
    }
    if (seen.add('${c.kind.name}:${c.code}')) kept.add(c);
  }

  int aicLengthRank(CodeCandidate c) =>
      c.kind == CodeKind.aic && c.code.length != 9 ? 1 : 0;
  final order = {for (var i = 0; i < kept.length; i++) kept[i]: i};
  kept.sort((a, b) {
    var cmp = a.kind.index.compareTo(b.kind.index);
    if (cmp != 0) return cmp;
    cmp = aicLengthRank(a).compareTo(aicLengthRank(b));
    if (cmp != 0) return cmp;
    cmp = a.box.top.compareTo(b.box.top);
    if (cmp != 0) return cmp;
    cmp = a.box.left.compareTo(b.box.left);
    if (cmp != 0) return cmp;
    return order[a]!.compareTo(order[b]!);
  });

  return kept.length > limit ? kept.sublist(0, limit) : kept;
}

/// Whether [digits] is an EAN-13 or EAN-8 with a valid check digit.
bool isValidEan(String digits) {
  if (digits.length != 13 && digits.length != 8) return false;
  if (!RegExp(r'^[0-9]+$').hasMatch(digits)) return false;
  var sum = 0;
  final last = digits.length - 1;
  for (var i = 0; i < last; i++) {
    final weight = (last - 1 - i).isEven ? 3 : 1;
    sum += int.parse(digits[i]) * weight;
  }
  return (10 - sum % 10) % 10 == int.parse(digits[last]);
}

// ── Internals ────────────────────────────────────────────────

/// Ministry of Health code labels on supplement packs, matched against the
/// upper-cased line; tolerant of OCR spacing and punctuation.
final _supplementLabel = RegExp(
  r'(?<![A-Z])(MIN[\s.:,\-]*SAN'
  r'|COD(ICE)?[\s.:,\-]*MIN(?![A-Z])'
  r'|CODICE[\s.:,\-]*MINISTERIALE'
  r'|CODICE[\s.:,\-]*(DI[\s.:,\-]*)?NOTIFICA'
  r'|NOTIFICA[\s.:,\-]*N(?![A-Z]))',
);

final _digitRun = RegExp(r'(?<![0-9])[0-9]{6,9}(?![0-9])');
final _digitGroups = RegExp(r'[0-9]+(?:[ ]+[0-9]+)*');
final _digitGroup = RegExp(r'[0-9]+');
final _token = RegExp(r'[A-Za-z0-9]+');
final _digit = RegExp(r'[0-9]');

class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;

  bool overlaps(_Span other) => start < other.end && other.start < end;
}

/// Finds valid EANs, joining space-separated digit groups when the joined
/// length is 13 or 8 and the checksum validates (13 preferred).
List<({String code, _Span span})> _findEans(String text) {
  final result = <({String code, _Span span})>[];
  for (final run in _digitGroups.allMatches(text)) {
    final groups = _digitGroup
        .allMatches(run[0]!)
        .map((g) => (text: g[0]!, start: run.start + g.start))
        .toList();
    var i = 0;
    while (i < groups.length) {
      var matched = false;
      for (final target in const [13, 8]) {
        final buffer = StringBuffer();
        for (var j = i; j < groups.length; j++) {
          buffer.write(groups[j].text);
          if (buffer.length > target) break;
          if (buffer.length == target) {
            final code = buffer.toString();
            if (isValidEan(code)) {
              final end = groups[j].start + groups[j].text.length;
              result.add((code: code, span: _Span(groups[i].start, end)));
              i = j + 1;
              matched = true;
            }
            break;
          }
        }
        if (matched) break;
      }
      if (!matched) i++;
    }
  }
  return result;
}

/// Character spans of each element inside the line text (null if an element
/// cannot be located).
List<_Span?> _elementSpans(OcrLine line) {
  final spans = <_Span?>[];
  var cursor = 0;
  for (final element in line.elements) {
    final index = element.text.isEmpty
        ? -1
        : line.text.indexOf(element.text, cursor);
    if (index < 0) {
      spans.add(null);
    } else {
      spans.add(_Span(index, index + element.text.length));
      cursor = index + element.text.length;
    }
  }
  return spans;
}
