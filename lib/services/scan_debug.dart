/// Medora - opt-in scanner diagnostics
///
/// Build with `--dart-define=SCAN_DEBUG=true` to log every recognised OCR
/// line and element, every decoded barcode and the resulting candidates as
/// `[scan] ...` lines (`adb logcat -s flutter` or `flutter logs`). Without
/// the define [scanDebug] is a false constant and the logging is compiled
/// out. Recogniser failures are logged regardless.
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:medora/services/code_candidates.dart';

const bool scanDebug = bool.fromEnvironment('SCAN_DEBUG');

/// Logs [messages] when [scanDebug] is on.
void scanLog(Iterable<String> messages) {
  if (!scanDebug) return;
  for (final message in messages) {
    debugPrint(message);
  }
}

/// `left,top widthxheight` in whole image pixels.
String describeRect(Rect r) =>
    '${r.left.round()},${r.top.round()} '
    '${r.width.round()}x${r.height.round()}';

/// One `[scan] line:` entry per OCR line, followed by its elements.
List<String> describeOcrLines(List<OcrLine> lines) => [
  for (final line in lines) ...[
    '[scan] line: ${line.text} @ ${describeRect(line.box)}',
    for (final element in line.elements)
      '[scan]   element: ${element.text} @ ${describeRect(element.box)}',
  ],
];

/// One `[scan] candidate:` entry per candidate.
List<String> describeCandidates(List<CodeCandidate> candidates) => [
  for (final c in candidates)
    '[scan] candidate: ${c.kind.name} ${c.code} '
        '(${c.sourceText}) @ ${describeRect(c.box)}'
        '${c.alternatives.isEmpty ? '' : ' or ${c.alternatives.join('/')}'}',
];
