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
}

class Code39Barcode extends StatelessWidget {
  const Code39Barcode(this.data, {super.key, this.height = 96});

  final String data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final modules = Code39.encode(data);
    if (modules == null) return const SizedBox.shrink();
    // Always black on white, whatever the theme: a scanner needs contrast
    // and a quiet zone, not the app's colours.
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _Code39Painter(modules)),
        ),
      ),
    );
  }
}

class _Code39Painter extends CustomPainter {
  _Code39Painter(this.modules);
  final List<bool> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final module = size.width / modules.length;
    final paint = Paint()..color = Colors.black;
    for (var i = 0; i < modules.length; i++) {
      if (!modules[i]) continue;
      canvas.drawRect(Rect.fromLTWH(i * module, 0, module, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_Code39Painter old) => old.modules != modules;
}
