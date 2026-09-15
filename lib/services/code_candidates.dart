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

  /// An EAN decoded by a barcode scanner rather than read by OCR; null unless
  /// [value] holds a valid EAN-13 / EAN-8.
  static CodeCandidate? eanFromBarcode(String value, Rect box) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (!isValidEan(digits)) return null;
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
/// shorter; a 6-8 digit AIC needs an AIC label), then supplement codes, then EAN barcodes, then other
/// number-like tokens (>= 6 alphanumerics with >= 4 digits, e.g. lot/batch).
/// Within a kind candidates run top-to-bottom, then left-to-right.
/// Deduplicated by kind and code (first occurrence wins), at most [limit].
///
/// [barcodes] are candidates decoded by a barcode scanner (see
/// [CodeCandidate.eanFromBarcode]); when OCR read the same kind and code, the
/// barcode's box is used and the OCR line text kept.
List<CodeCandidate> findCodeCandidates(
  List<OcrLine> lines, {
  List<CodeCandidate> barcodes = const [],
  int limit = 20,
}) {
  final found = <CodeCandidate>[];
  final labelPartners = _labelPartners(lines);

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    final text = _repairCodeTokens(line.text);
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
          sourceText: line.text.trim(),
          box: boxFor(span),
        ),
      );
    }

    // EAN-13 / EAN-8 printed as a whole digit run (a failed checksum yields
    // one "other" candidate for the run).
    for (final ean in _findEans(text)) {
      claimed.add(ean.span);
      add(ean.code, ean.kind, ean.span);
    }

    // Supplement code: the first number after the label on a labelled line,
    // else the first number on the line paired with a label line without
    // one (same row to its right, or right below; see [_labelPartners]).
    final label = _supplementLabel.firstMatch(text);
    var supplement = label == null
        ? null
        : _labelledCode(text, label.end, claimed);
    if (supplement == null && labelPartners.contains(lineIndex)) {
      supplement = _labelledCode(text, 0, claimed);
    }
    if (supplement != null) {
      claimed.add(supplement);
      add(
        text.substring(supplement.start, supplement.end),
        CodeKind.supplement,
        supplement,
      );
    }

    // AIC codes: optional letter + 9 digits, not already claimed; 6-8 digits
    // only after an AIC label on the line (unlabelled, they are "other").
    final aicLabel = _aicLabel.firstMatch(text);
    for (final m in BarcodeLookupDatasource.aicPattern.allMatches(text)) {
      final span = _Span(m.start, m.end);
      if (isClaimed(span)) continue;
      final code = BarcodeLookupDatasource.cleanCode(m[0]!);
      if (code.length < 6) continue;
      if (code.length < 9 && (aicLabel == null || m.start < aicLabel.end)) {
        continue;
      }
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

  // Merge barcode-decoded candidates: their box wins over the OCR one.
  for (final barcode in barcodes) {
    final index = found.indexWhere(
      (c) => c.kind == barcode.kind && c.code == barcode.code,
    );
    if (index < 0) {
      found.add(barcode);
    } else {
      final ocrText = found[index].sourceText;
      found[index] = CodeCandidate(
        code: barcode.code,
        kind: barcode.kind,
        sourceText: ocrText.isEmpty ? barcode.sourceText : ocrText,
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

/// Ministry of Health code labels on supplement packs (case-insensitive):
/// COD MINSAN, COD. MIN., CODICE MINISTERIALE, CODICE (DI) NOTIFICA,
/// NOTIFICA N. Tolerant of OCR spacing and punctuation (missing, extra or
/// none, e.g. `CODMINSAN`) and of the usual letter/digit confusions in the
/// label itself: O read as 0 and I read as l or 1 (`C0D MlNSAN`).
final _supplementLabel = () {
  const o = '[O0]';
  const i = '[Il1]';
  const sep = r'[\s.:,;\-]*';
  return RegExp(
    '(?<![A-Z])(?:'
    'C${o}D(?:${i}CE)?${sep}M${i}N$sep(?:SAN|${i}STER${i}ALE)'
    '|C${o}D(?:${i}CE)?${sep}M${i}N(?![A-Z])'
    '|C${o}D${i}CE$sep(?:D$i$sep)?N${o}T${i}F${i}CA'
    '|M${i}N${sep}SAN'
    '|N${o}T${i}F${i}CA${sep}N(?![A-Z]))',
    caseSensitive: false,
  );
}();

/// The AIC label on medicine packs (case-insensitive): AIC, A.I.C., A I C.
final _aicLabel = RegExp(
  r'(?<![A-Za-z])A[.\s]?I[.\s]?C(?![A-Za-z])',
  caseSensitive: false,
);

/// A supplement code right after a label: 3-9 digits. Register codes run
/// from 2 to 7 digits (2: ~140 rows, 3: ~970, 4: ~1,050, 5: ~25,600, 6:
/// ~86,100); 2-digit codes are not accepted because after a label they are
/// far more often a quantity or a date part than one of those few products.
final _labelledDigitRun = RegExp(
  r'(?<![0-9])(?<![0-9][/.,])[0-9]{3,9}(?![0-9])',
);

/// What makes a number after a label a quantity or a date, not a code:
/// `/`, a decimal part, `%` or a unit.
final _quantitySuffix = RegExp(
  r'(?:[/.,][0-9]|/|\s*(?:%|(?:mg|g|ml|kcal)(?![A-Za-z])))',
  caseSensitive: false,
);

/// A line holding nothing but a possible labelled code.
final _onlyDigitRun = RegExp(r'^[0-9]{3,9}$');

/// A run of digit groups separated by single spaces, with no letter or digit
/// directly before it.
final _digitGroups = RegExp(r'(?<![A-Za-z0-9])[0-9]+(?: [0-9]+)*');

/// Group lengths an EAN-13 / EAN-8 is printed in.
/// `1,12` and `12,1` are how on-device OCR merges a printed `8 057737 141836`.
const _eanShapes = {'13', '1,6,6', '7,6', '1,12', '12,1', '8', '4,4'};
final _token = RegExp(r'[A-Za-z0-9]+');
final _digit = RegExp(r'[0-9]');

class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;

  bool overlaps(_Span other) => start < other.end && other.start < end;
}

/// Finds EAN-shaped digit runs (see [_eanShapes]): a valid checksum yields
/// an EAN, a failed one an "other" candidate with the joined digits. A single
/// 8-digit run with a failed checksum is left to the later rules (it may be
/// a supplement or AIC code).
List<({String code, CodeKind kind, _Span span})> _findEans(String text) {
  final result = <({String code, CodeKind kind, _Span span})>[];
  for (final run in _digitGroups.allMatches(text)) {
    final groups = run[0]!.split(' ');
    if (!_eanShapes.contains(groups.map((g) => g.length).join(','))) continue;
    final code = groups.join();
    final span = _Span(run.start, run.end);
    if (isValidEan(code)) {
      result.add((code: code, kind: CodeKind.ean, span: span));
    } else if (groups.length > 1 || code.length == 13) {
      result.add((code: code, kind: CodeKind.other, span: span));
    }
  }
  return result;
}

/// The first acceptable supplement code in [text] at or after [from]: see
/// [_labelledDigitRun], skipping [claimed] spans and quantities or dates
/// ([_quantitySuffix]).
_Span? _labelledCode(String text, int from, List<_Span> claimed) {
  for (final m in _labelledDigitRun.allMatches(text, from)) {
    final span = _Span(m.start, m.end);
    if (claimed.any((c) => c.overlaps(span))) continue;
    if (_quantitySuffix.matchAsPrefix(text, m.end) != null) continue;
    return span;
  }
  return null;
}

/// Indexes of the lines that hold the code of a supplement label printed
/// without one on its own line. ML Kit may put the number in another block
/// (so anywhere in [lines]): a line on the same row to the right of the
/// label (vertical centres within half a label height) is preferred, the
/// nearest one holding a code; otherwise the line right after the label in
/// reading order, when [_followsLabel] accepts it.
Set<int> _labelPartners(List<OcrLine> lines) {
  final partners = <int>{};
  for (var i = 0; i < lines.length; i++) {
    final label = lines[i];
    final labelText = _repairCodeTokens(label.text);
    final match = _supplementLabel.firstMatch(labelText);
    if (match == null) continue;
    final eanSpans = [for (final e in _findEans(labelText)) e.span];
    if (_labelledCode(labelText, match.end, eanSpans) != null) continue;

    int? sameRow;
    for (var j = 0; j < lines.length; j++) {
      if (j == i) continue;
      final other = lines[j];
      if (!_onSameRowRightOf(label, other)) continue;
      final spans = [for (final e in _findEans(other.text)) e.span];
      if (_labelledCode(other.text, 0, spans) == null) continue;
      if (sameRow == null || other.box.left < lines[sameRow].box.left) {
        sameRow = j;
      }
    }
    if (sameRow != null) {
      partners.add(sameRow);
    } else if (i + 1 < lines.length && _followsLabel(label, lines[i + 1])) {
      partners.add(i + 1);
    }
  }
  return partners;
}

/// Whether [other] sits on the same text row as [label] and starts to its
/// right (allowing half a line height of overlap for loose OCR boxes).
bool _onSameRowRightOf(OcrLine label, OcrLine other) {
  final height = label.box.height;
  final sameRow =
      (other.box.center.dy - label.box.center.dy).abs() <= height / 2;
  return sameRow && other.box.left >= label.box.right - height / 2;
}

/// Whether [next] is the line right below the supplement [label] line: it
/// holds only the number, or starts within 1.5 label heights below the label
/// and overlaps it horizontally.
bool _followsLabel(OcrLine label, OcrLine next) {
  if (_onlyDigitRun.hasMatch(next.text.trim())) return true;
  final gap = next.box.top - label.box.bottom;
  final below = next.box.top >= label.box.top && gap <= 1.5 * label.box.height;
  final overlaps =
      next.box.left < label.box.right && label.box.left < next.box.right;
  return below && overlaps;
}

/// OCR letters read in place of digits, mapped by [_repairCodeTokens].
const _digitLookalikes = {
  'O': '0', 'o': '0', 'Q': '0', 'D': '0', //
  'I': '1', 'l': '1', '|': '1', 'i': '1', '!': '1', //
  'Z': '2', 'z': '2', 'S': '5', 's': '5', 'G': '6', 'b': '6', //
  'T': '7', 't': '7', '?': '7', 'B': '8', 'g': '9', 'q': '9',
};

final _nonSpaceRun = RegExp(r'\S+');
final _edgePunctuation = RegExp(r'^[.:,;]+|[.:,;]+$');

/// [text] with digit lookalikes ([_digitLookalikes]) replaced in the first
/// two tokens after a supplement or AIC label, character for character (so
/// spans and element boxes still line up). A token is repaired only when it
/// holds at least 3 digits, at least half of it is digits, every other
/// character is a lookalike and it does not end in a quantity unit
/// (`100g`); e.g. `COD MINSAN: 10T018` becomes `COD MINSAN: 107018`.
String _repairCodeTokens(String text) {
  final labelEnds = [
    for (final label in [_supplementLabel, _aicLabel])
      ?label.firstMatch(text)?.end,
  ];
  if (labelEnds.isEmpty) return text;
  final chars = text.split('');
  for (final from in labelEnds) {
    for (final m in _nonSpaceRun.allMatches(text, from).take(2)) {
      final raw = m[0]!;
      final leading = _edgePunctuation.matchAsPrefix(raw)?.end ?? 0;
      final token = raw.replaceAll(_edgePunctuation, '');
      final start = m.start + leading;
      final digits = _digit.allMatches(token).length;
      if (digits < 3 || digits * 2 < token.length) continue;
      if (token.length > 9) continue;
      var repairable = true;
      for (var k = 0; k < token.length && repairable; k++) {
        final c = token[k];
        if (_digit.hasMatch(c)) continue;
        final unit = _quantitySuffix.matchAsPrefix(text, start + k);
        repairable =
            _digitLookalikes.containsKey(c) &&
            (unit == null || unit.end < start + token.length);
      }
      if (!repairable || digits == token.length) continue;
      for (var k = 0; k < token.length; k++) {
        chars[start + k] = _digitLookalikes[token[k]] ?? token[k];
      }
    }
  }
  return chars.join();
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
