import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/scan_debug.dart';

void main() {
  test('scan diagnostics are off unless SCAN_DEBUG is defined', () {
    expect(scanDebug, isFalse);
  });

  test('describeOcrLines lists each line and its elements with boxes', () {
    const lines = [
      OcrLine('COD MINSAN: 107018', Rect.fromLTWH(10.4, 20, 300, 40.6), [
        OcrElement('COD', Rect.fromLTWH(10, 20, 60, 40)),
        OcrElement('107018', Rect.fromLTWH(200, 20, 110, 40)),
      ]),
    ];
    expect(describeOcrLines(lines), [
      '[scan] line: COD MINSAN: 107018 @ 10,20 300x41',
      '[scan]   element: COD @ 10,20 60x40',
      '[scan]   element: 107018 @ 200,20 110x40',
    ]);
  });

  test('describeCandidates names kind, code and source line', () {
    const candidate = CodeCandidate(
      code: '107018',
      kind: CodeKind.supplement,
      sourceText: 'COD MINSAN: 107018',
      box: Rect.fromLTWH(200, 20, 110, 40),
    );
    expect(describeCandidates([candidate]), [
      '[scan] candidate: supplement 107018 (COD MINSAN: 107018) @ 200,20 110x40',
    ]);
  });
}
