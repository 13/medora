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
    this.alternatives = const [],
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

  /// Other readings of [code] when OCR read an ambiguous lookalike in it
  /// (`T` for 7 or 1, see [_ambiguousLookalikes]): unique, without [code],
  /// fewest changed characters first, at most [maxCodeAlternatives]. A
  /// lookup can try them in order when [code] itself is not found.
  final List<String> alternatives;

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
  // Where each accepted EAN was read: its OCR line boxes and barcode boxes.
  final eanAreas = <String, List<Rect>>{};
  final labelPartners = _labelPartners(lines);

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    final (:text, :repairs) = _repairCodeTokens(line.text);
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

    void add(
      String code,
      CodeKind kind,
      _Span span, {
      String Function(String)? codeOf,
    }) {
      found.add(
        CodeCandidate(
          code: code,
          kind: kind,
          sourceText: line.text.trim(),
          box: boxFor(span),
          alternatives: codeOf == null
              ? const []
              : _alternativeCodes(text, span, repairs, code, codeOf),
        ),
      );
    }

    // EAN-13 / EAN-8 printed as a whole digit run (a failed checksum yields
    // one "other" candidate for the run).
    for (final ean in _findEans(text)) {
      claimed.add(ean.span);
      add(ean.code, ean.kind, ean.span);
      if (ean.kind == CodeKind.ean) {
        (eanAreas[ean.code] ??= []).add(line.box);
      }
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
        codeOf: (digits) => digits,
      );
    }

    // AIC codes: optional letter + 9 digits, not already claimed; 6-8 digits
    // only as the first number after an AIC label on the line (unlabelled,
    // they are "other").
    final aicLabel = _aicLabel.firstMatch(text);
    for (final m in BarcodeLookupDatasource.aicPattern.allMatches(text)) {
      final span = _Span(m.start, m.end);
      if (isClaimed(span)) continue;
      final code = BarcodeLookupDatasource.cleanCode(m[0]!);
      if (code.length < 6) continue;
      if (code.length < 9 &&
          (aicLabel == null ||
              m.start < aicLabel.end ||
              _digit.hasMatch(text.substring(aicLabel.end, m.start)))) {
        continue;
      }
      claimed.add(span);
      add(code, CodeKind.aic, span, codeOf: BarcodeLookupDatasource.cleanCode);
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
    if (barcode.kind == CodeKind.ean) {
      (eanAreas[barcode.code] ??= []).add(barcode.box);
    }
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
        alternatives: found[index].alternatives,
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

  // A digit run inside an EAN, read where that EAN was read, is a piece of
  // the EAN's printed digits (e.g. `057737` of `8 "057737"141836`).
  bool isEanPiece(CodeCandidate c) =>
      (c.kind == CodeKind.aic || c.kind == CodeKind.other) &&
      _allDigits.hasMatch(c.code) &&
      eanAreas.entries.any(
        (e) => e.key.contains(c.code) && e.value.any(c.box.overlaps),
      );

  final seen = <String>{};
  final kept = <CodeCandidate>[];
  for (final c in found) {
    if (c.kind == CodeKind.aic && supplementCodes.contains(c.code)) continue;
    if (isEanPiece(c)) continue;
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

/// The code kinds whose label appears in [lines]: [CodeKind.supplement]
/// for a Ministry of Health label (COD MINSAN, ...), [CodeKind.aic] for an
/// AIC label.
Set<CodeKind> codeLabelKinds(List<OcrLine> lines) => {
  for (final line in lines) ...[
    if (_supplementLabel.hasMatch(line.text)) CodeKind.supplement,
    if (_aicLabel.hasMatch(line.text)) CodeKind.aic,
  ],
};

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

/// A run of digit groups, with no letter or digit directly before it,
/// separated by a single space, by up to two quotes, apostrophes or
/// backticks with an optional space on either side, or by up to two of
/// those, commas or dots with an optional space before them only (OCR of
/// `8 057737 141836` can read `8 "057737"141836`). A comma or dot followed
/// by a space ends the run: `SCAD. 2026. 8057737141836` is a date, then an
/// EAN.
final _digitGroups = RegExp(
  '(?<![A-Za-z0-9])[0-9]+'
  '(?:(?: |\\s?$_groupQuotes{1,2}\\s|\\s?$_groupPunctuation{1,2})[0-9]+)*',
);
const _groupQuotes = '["\'`\u2018\u2019\u201C\u201D]';
const _groupPunctuation = '["\'`,.\u2018\u2019\u201C\u201D]';
final _nonDigits = RegExp(r'[^0-9]+');
final _digitRun = RegExp(r'[0-9]+');
final _allDigits = RegExp(r'^[0-9]+$');

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
/// a supplement or AIC code), and so are groups joined by punctuation (see
/// [_digitGroups]) unless they form a valid EAN; `4,4` groups join only
/// with a space (`1234.5670` is a price). In a run that is no EAN shape, a
/// single 13-digit group with a valid checksum is still an EAN
/// (`EAN 8057737141836 20 g`).
List<({String code, CodeKind kind, _Span span})> _findEans(String text) {
  final result = <({String code, CodeKind kind, _Span span})>[];
  for (final run in _digitGroups.allMatches(text)) {
    final runText = run[0]!;
    final groups = runText.split(_nonDigits);
    final shape = groups.map((g) => g.length).join(',');
    final punctuated = runText.contains(RegExp(_groupPunctuation));
    if (!_eanShapes.contains(shape) || (punctuated && shape == '4,4')) {
      for (final group in _digitRun.allMatches(runText)) {
        final code = group[0]!;
        if (code.length != 13 || !isValidEan(code)) continue;
        final span = _Span(run.start + group.start, run.start + group.end);
        result.add((code: code, kind: CodeKind.ean, span: span));
      }
      continue;
    }
    final code = groups.join();
    final span = _Span(run.start, run.end);
    if (isValidEan(code)) {
      result.add((code: code, kind: CodeKind.ean, span: span));
    } else if (!punctuated && (groups.length > 1 || code.length == 13)) {
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
    final labelText = _repairCodeTokens(label.text).text;
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

/// The most alternatives a candidate carries ([CodeCandidate.alternatives]).
const maxCodeAlternatives = 16;

/// OCR letters read in place of digits, mapped by [_repairCodeTokens].
const _digitLookalikes = {
  'O': '0', 'o': '0', 'Q': '0', 'D': '0', //
  'I': '1', 'l': '1', '|': '1', 'i': '1', '!': '1', //
  'Z': '2', 'z': '2', 'S': '5', 's': '5', 'G': '6', 'b': '6', //
  'T': '7', 't': '7', '?': '7', 'B': '8', 'g': '9', 'q': '9',
};

/// Lookalikes OCR reads for two digits: the second digit of each, the first
/// being its [_digitLookalikes] mapping.
const _ambiguousLookalikes = {
  'T': '1', 't': '1', '?': '1', //
  'l': '7', 'I': '7', '|': '7', 'i': '7', '!': '7', //
  'B': '3', 'G': '0',
};

final _nonSpaceRun = RegExp(r'\S+');
final _edgePunctuation = RegExp(r'^[.:,;]+|[.:,;]+$');

/// [text] with digit lookalikes ([_digitLookalikes]) replaced in the first
/// two tokens after a supplement label and in the first two tokens up to
/// the first one holding a digit after an AIC label (so a second number is
/// not turned into a code), character for character (so
/// spans and element boxes still line up). A token is repaired only when it
/// holds at least 3 digits, at least half of it is digits, every other
/// character is a lookalike and it does not end in a quantity unit
/// (`100g`); e.g. `COD MINSAN: 10T018` becomes `COD MINSAN: 107018`.
/// [repairs] maps each replaced position to the original character.
({String text, Map<int, String> repairs}) _repairCodeTokens(String text) {
  final repairs = <int, String>{};
  final labels = [
    if (_supplementLabel.firstMatch(text) case final m?)
      (end: m.end, aic: false),
    if (_aicLabel.firstMatch(text) case final m?) (end: m.end, aic: true),
  ];
  if (labels.isEmpty) return (text: text, repairs: repairs);
  final chars = text.split('');

  void repair(int start, String token) {
    final digits = _digit.allMatches(token).length;
    if (digits < 3 || digits * 2 < token.length) return;
    if (token.length > 9 || digits == token.length) return;
    for (var k = 0; k < token.length; k++) {
      final c = token[k];
      if (_digit.hasMatch(c)) continue;
      final unit = _quantitySuffix.matchAsPrefix(text, start + k);
      final repairable =
          _digitLookalikes.containsKey(c) &&
          (unit == null || unit.end < start + token.length);
      if (!repairable) return;
    }
    for (var k = 0; k < token.length; k++) {
      final digit = _digitLookalikes[token[k]];
      if (digit == null) continue;
      chars[start + k] = digit;
      repairs[start + k] = token[k];
    }
  }

  for (final (:end, :aic) in labels) {
    for (final m in _nonSpaceRun.allMatches(text, end).take(2)) {
      final raw = m[0]!;
      final leading = _edgePunctuation.matchAsPrefix(raw)?.end ?? 0;
      final token = raw.replaceAll(_edgePunctuation, '');
      repair(m.start + leading, token);
      // After an AIC label only the first token with a digit is the code.
      if (aic && _digit.hasMatch(token)) break;
    }
  }
  return (text: chars.join(), repairs: repairs);
}

/// The other codes [span] of the repaired [text] reads as when its
/// ambiguous lookalikes ([repairs] holding an [_ambiguousLookalikes] key)
/// take their second digit, each cleaned by [codeOf]; fewest changes first,
/// then leftmost, unique, without [code], at most [maxCodeAlternatives].
List<String> _alternativeCodes(
  String text,
  _Span span,
  Map<int, String> repairs,
  String code,
  String Function(String) codeOf,
) {
  final positions = [
    for (var i = span.start; i < span.end; i++)
      if (_ambiguousLookalikes.containsKey(repairs[i])) i,
  ];
  if (positions.isEmpty) return const [];
  // Every non-empty subset of positions, as bit masks, fewest bits first;
  // ties keep the order in which lower positions change first.
  final masks = [for (var m = 1; m < 1 << positions.length; m++) m];
  int bits(int m) => m.toRadixString(2).replaceAll('0', '').length;
  int reversed(int m) {
    var r = 0;
    for (var b = 0; b < positions.length; b++) {
      if (m & (1 << b) != 0) r |= 1 << (positions.length - 1 - b);
    }
    return r;
  }

  masks.sort((a, b) {
    final cmp = bits(a).compareTo(bits(b));
    return cmp != 0 ? cmp : reversed(b).compareTo(reversed(a));
  });
  final result = <String>{};
  for (final mask in masks) {
    final chars = text.substring(span.start, span.end).split('');
    for (var b = 0; b < positions.length; b++) {
      if (mask & (1 << b) == 0) continue;
      final i = positions[b];
      chars[i - span.start] = _ambiguousLookalikes[repairs[i]]!;
    }
    final alternative = codeOf(chars.join());
    if (alternative != code) result.add(alternative);
    if (result.length == maxCodeAlternatives) break;
  }
  return result.toList();
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
