/// Medora - Code 128 barcodes, as printed on an Italian electronic
/// prescription (the pharmacy scans the NRE/NRBE and the tax code from the
/// phone screen the same way it scans them from paper).
///
/// Each symbol is six elements (three bars, three spaces), 11 modules wide,
/// bar first; the stop symbol adds a fourth bar (13 modules) so the
/// barcode can be read in either direction. 107 symbol values (0–106):
/// 0–95 are set B (space…DEL, value = ASCII − 32), 96–102 are function/
/// shift/code-set symbols this encoder never emits, 103–105 are the three
/// start symbols (only Start B = 104 and Start C = 105 are used here) and
/// 106 is the stop symbol. Table taken from the "Bar/Space" pattern column
/// of the Code 128 table on Wikipedia (en.wikipedia.org/wiki/Code_128,
/// checked 2026-09-24) and cross-checked by decoding rendered barcodes with
/// zxing-cpp.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:medora/presentation/widgets/barcode_layout.dart';

abstract final class Code128 {
  static const _startB = 104;
  static const _startC = 105;
  static const _stop = 106;

  /// Each symbol value's 11 modules (dark = `1`), values 0–106 in order.
  static const _patterns = [
    '11011001100',
    '11001101100',
    '11001100110',
    '10010011000',
    '10010001100',
    '10001001100',
    '10011001000',
    '10011000100',
    '10001100100',
    '11001001000',
    '11001000100',
    '11000100100',
    '10110011100',
    '10011011100',
    '10011001110',
    '10111001100',
    '10011101100',
    '10011100110',
    '11001110010',
    '11001011100',
    '11001001110',
    '11011100100',
    '11001110100',
    '11101101110',
    '11101001100',
    '11100101100',
    '11100100110',
    '11101100100',
    '11100110100',
    '11100110010',
    '11011011000',
    '11011000110',
    '11000110110',
    '10100011000',
    '10001011000',
    '10001000110',
    '10110001000',
    '10001101000',
    '10001100010',
    '11010001000',
    '11000101000',
    '11000100010',
    '10110111000',
    '10110001110',
    '10001101110',
    '10111011000',
    '10111000110',
    '10001110110',
    '11101110110',
    '11010001110',
    '11000101110',
    '11011101000',
    '11011100010',
    '11011101110',
    '11101011000',
    '11101000110',
    '11100010110',
    '11101101000',
    '11101100010',
    '11100011010',
    '11101111010',
    '11001000010',
    '11110001010',
    '10100110000',
    '10100001100',
    '10010110000',
    '10010000110',
    '10000101100',
    '10000100110',
    '10110010000',
    '10110000100',
    '10011010000',
    '10011000010',
    '10000110100',
    '10000110010',
    '11000010010',
    '11001010000',
    '11110111010',
    '11000010100',
    '10001111010',
    '10100111100',
    '10010111100',
    '10010011110',
    '10111100100',
    '10011110100',
    '10011110010',
    '11110100100',
    '11110010100',
    '11110010010',
    '11011011110',
    '11011110110',
    '11110110110',
    '10101111000',
    '10100011110',
    '10001011110',
    '10111101000',
    '10111100010',
    '11110101000',
    '11110100010',
    '10111011110',
    '10111101110',
    '11101011110',
    '11110101110',
    '11010000100',
    '11010010000',
    '11010011100',
    '11000111010',
  ];

  static final _digits = RegExp(r'^[0-9]+$');

  /// Code 128 modules (true = dark) for [data], with start, checksum and
  /// stop; set C for an all-digit string of even length ≥ 4, else set B.
  /// Null when a character is outside set B (ASCII 32–127).
  static List<bool>? encode(String data) {
    final useC =
        data.length >= 4 && data.length.isEven && _digits.hasMatch(data);
    final values = <int>[];
    if (useC) {
      for (var i = 0; i < data.length; i += 2) {
        values.add(int.parse(data.substring(i, i + 2)));
      }
    } else {
      for (final unit in data.codeUnits) {
        if (unit < 32 || unit > 127) return null;
        values.add(unit - 32);
      }
    }

    final start = useC ? _startC : _startB;
    var checksum = start;
    for (var i = 0; i < values.length; i++) {
      checksum += (i + 1) * values[i];
    }
    checksum %= 103;

    final modules = <bool>[];
    for (final symbol in [start, ...values, checksum, _stop]) {
      for (final e in _patterns[symbol].split('')) {
        modules.add(e == '1');
      }
    }
    // The stop symbol's 11 modules end the encoded data; the final bar
    // (2 modules, always dark) is a separate, fixed element that lets the
    // barcode be read in either direction.
    modules.addAll([true, true]);
    return modules;
  }
}

class Code128Barcode extends StatelessWidget {
  const Code128Barcode(this.data, {super.key, this.height = 96});

  final String data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final modules = Code128.encode(data);
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
            // The full width goes to BarcodeLayout.layout, which sizes the
            // quiet zone in from the start; painting must use that same
            // full width, or the canvas is narrowed a second time and the
            // bars spread back into the quiet zone it just computed.
            final layout = BarcodeLayout.layout(
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
                  painter: _Code128Painter(
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

class _Code128Painter extends CustomPainter {
  _Code128Painter(this.modules, {required this.module, required this.left});

  final List<bool> modules;
  final double module;

  /// Left offset of the first bar, as computed by [BarcodeLayout.layout] —
  /// already centred and clear of the quiet zone.
  final double left;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (final (start, length) in BarcodeLayout.darkRuns(modules)) {
      canvas.drawRect(
        Rect.fromLTWH(left + start * module, 0, length * module, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Code128Painter old) =>
      !listEquals(old.modules, modules) ||
      old.module != module ||
      old.left != left;
}
