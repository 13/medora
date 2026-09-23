/// Medora - Code 39 barcodes, as printed on an Italian prescription
/// reminder: the pharmacy scans the NRE and the tax code from the phone
/// screen the same way it scans them from paper.
///
/// Code 39 needs no check digit and no library: each character is nine
/// elements (five bars, four spaces), three of them wide. Table checked
/// against python-barcode's `barcode/charsets/code39.py` (ISO/IEC 16388),
/// decoded back to its narrow/wide pattern; it matches this one entry for
/// entry, including the `*` start/stop character.
library;

import 'dart:math' show max;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

abstract final class Code39 {
  /// Each character's nine elements, bar first, `1` = wide.
  static const _patterns = {
    '0': '000110100',
    '1': '100100001',
    '2': '001100001',
    '3': '101100000',
    '4': '000110001',
    '5': '100110000',
    '6': '001110000',
    '7': '000100101',
    '8': '100100100',
    '9': '001100100',
    'A': '100001001',
    'B': '001001001',
    'C': '101001000',
    'D': '000011001',
    'E': '100011000',
    'F': '001011000',
    'G': '000001101',
    'H': '100001100',
    'I': '001001100',
    'J': '000011100',
    'K': '100000011',
    'L': '001000011',
    'M': '101000010',
    'N': '000010011',
    'O': '100010010',
    'P': '001010010',
    'Q': '000000111',
    'R': '100000110',
    'S': '001000110',
    'T': '000010110',
    'U': '110000001',
    'V': '011000001',
    'W': '111000000',
    'X': '010010001',
    'Y': '110010000',
    'Z': '011010000',
    '-': '010000101',
    '.': '110000100',
    ' ': '011000100',
    '*': '010010100',
  };

  static const _wide = 3;

  /// The modules of `*data*` (dark = true), a narrow space between
  /// characters; null when [data] holds a character Code 39 lacks.
  static List<bool>? encode(String data) {
    final modules = <bool>[];
    final chars = '*$data*'.split('');
    for (var c = 0; c < chars.length; c++) {
      final pattern = _patterns[chars[c]];
      if (pattern == null) return null;
      for (var e = 0; e < 9; e++) {
        final dark = e.isEven;
        final width = pattern[e] == '1' ? _wide : 1;
        for (var w = 0; w < width; w++) {
          modules.add(dark);
        }
      }
      if (c < chars.length - 1) modules.add(false);
    }
    return modules;
  }

  /// The module width, quiet zone and left offset to paint `modules`
  /// modules into a canvas `width` dp wide at device pixel ratio `dpr`.
  ///
  /// The module is snapped to a whole number of device pixels (so wide
  /// bars stay an exact multiple of narrow ones and painting needs no
  /// antialiasing). The quiet zone is at least 16dp and at least 10
  /// modules — a real scanner needs that clear margin either side of the
  /// bars, so it is sized in from the start (`modules + 20` stands in for
  /// the bars plus roughly two quiet zones) rather than computed from a
  /// module picked to fill the whole width and then carved out of it,
  /// which starved the quiet zone or pushed bars past the edges on a
  /// narrow screen.
  static ({double module, double quietZone, double left}) layout({
    required double width,
    required double dpr,
    required int modules,
  }) {
    var mpx = max(1, (width * dpr / (modules + 20)).floor());
    var module = mpx / dpr;
    var quietZone = max(16.0, 10 * module);
    while (modules * module + 2 * quietZone > width && mpx > 1) {
      mpx--;
      module = mpx / dpr;
      quietZone = max(16.0, 10 * module);
    }
    // Centred, snapped to whole device pixels like the module itself.
    final left = ((width - modules * module) / 2 * dpr).floor() / dpr;
    return (module: module, quietZone: quietZone, left: left);
  }

  /// Runs of consecutive dark modules in [modules], as `(start, length)`
  /// pairs — one per bar, so the painter draws one rect per bar instead of
  /// one per module (which left antialiased seams inside wide bars).
  static List<(int start, int length)> darkRuns(List<bool> modules) {
    final runs = <(int, int)>[];
    var i = 0;
    while (i < modules.length) {
      if (!modules[i]) {
        i++;
        continue;
      }
      final start = i;
      while (i < modules.length && modules[i]) {
        i++;
      }
      runs.add((start, i - start));
    }
    return runs;
  }
}

class Code39Barcode extends StatelessWidget {
  const Code39Barcode(this.data, {super.key, this.height = 96});

  final String data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final modules = Code39.encode(data);
    if (modules == null) return const SizedBox.shrink();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Always black on white, whatever the theme: a scanner needs contrast
    // and a quiet zone, not the app's colours.
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The full width goes to Code39.layout, which sizes the quiet
            // zone in from the start; painting must use that same full
            // width, or the canvas is narrowed a second time and the bars
            // spread back into the quiet zone it just computed.
            final layout = Code39.layout(
              width: constraints.maxWidth,
              dpr: dpr,
              modules: modules.length,
            );
            // ClipRect: a screen too narrow even for the shrunk-to-1px
            // module still must not paint past this widget's bounds.
            return ClipRect(
              child: SizedBox(
                height: height,
                width: double.infinity,
                child: CustomPaint(
                  painter: _Code39Painter(
                    modules,
                    module: layout.module,
                    left: layout.left,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Code39Painter extends CustomPainter {
  _Code39Painter(this.modules, {required this.module, required this.left});

  final List<bool> modules;
  final double module;

  /// Left offset of the first bar, as computed by [Code39.layout] — already
  /// centred and clear of the quiet zone.
  final double left;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (final (start, length) in Code39.darkRuns(modules)) {
      canvas.drawRect(
        Rect.fromLTWH(left + start * module, 0, length * module, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Code39Painter old) =>
      !listEquals(old.modules, modules) ||
      old.module != module ||
      old.left != left;
}
