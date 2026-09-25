import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/barcode_layout.dart';
import 'package:medora/presentation/widgets/code128.dart';

/// Turns a string of `0`/`1` into the `List<bool>` [Code128.encode] returns
/// (`1` = dark), for hand-checked expectations below.
List<bool> _bits(String s) => s.split('').map((c) => c == '1').toList();

void main() {
  group('Code128.encode — known encodings (Wikipedia Code 128 table)', () {
    // `7XQ2K` in set B: start B (104), values [23,56,49,18,43] (chars
    // '7','X','Q','2','K' minus 32), checksum=(104+1*23+2*56+3*49+4*18+
    // 5*43)%103=55; patterns[104], the five values, patterns[55]
    // (checksum), patterns[106] (stop) and the final 2-module bar — 90
    // modules, cross-checked by decoding a rendered barcode with zxing-cpp
    // (see the render test below).
    test('encode(7XQ2K) — set B, checksum 55', () {
      const expected =
          '110100100001110110111011100010110110100011101100111001010110001'
          '110111010001101100011101011';
      expect(Code128.encode('7XQ2K'), _bits(expected));
    });

    // `0012345678` in set C: start C (105), digit pairs [00,12,34,56,78],
    // checksum=(105+1*0+2*12+3*34+4*56+5*78)%103=21.
    test('encode(0012345678) — set C, checksum 21', () {
      const expected =
          '110100111001101100110010110011100100010110001110001011011000010'
          '100110111001001100011101011';
      expect(Code128.encode('0012345678'), _bits(expected));
    });

    test('starts with Start B (104) for a non-digit string', () {
      final modules = Code128.encode('7XQ2K')!;
      // patterns[104] = 11010010000
      expect(modules.sublist(0, 11), _bits('11010010000'));
    });

    test('starts with Start C (105) for an all-digit even-length string', () {
      final modules = Code128.encode('0012345678')!;
      // patterns[105] = 11010011100
      expect(modules.sublist(0, 11), _bits('11010011100'));
    });

    test('an odd-length or short digit string uses set B, not set C', () {
      // '123' is 3 digits (< 4): set B, one symbol per character.
      final modules = Code128.encode('123')!;
      expect(modules.sublist(0, 11), _bits('11010010000')); // Start B
      // Total = 11 * (3 symbols + start + check) + 13.
      expect(modules.length, 11 * (3 + 2) + 13);
    });

    // `12345`: all digits but odd length, so set B (set C needs digit
    // pairs): start B (104), values [17,18,19,20,21] ('1'..'5' minus 32),
    // checksum=(104+1*17+2*18+3*19+4*20+5*21)%103=90; patterns[104], the
    // five values, patterns[90], patterns[106] and the final 2-module bar.
    test('encode(12345) — odd-length digits use set B, checksum 90', () {
      const expected =
          '11010010000' // start B
          '10011100110' // 17 '1'
          '11001110010' // 18 '2'
          '11001011100' // 19 '3'
          '11001001110' // 20 '4'
          '11011100100' // 21 '5'
          '11011110110' // 90 checksum
          '11000111010' // stop
          '11';
      expect(Code128.encode('12345'), _bits(expected));
    });

    test('ends with the stop pattern (11000111010) plus the final 2-module '
        'bar', () {
      for (final data in ['7XQ2K', '0012345678', 'G00001234567']) {
        final modules = Code128.encode(data)!;
        expect(modules.sublist(modules.length - 13), _bits('1100011101011'));
      }
    });

    test('total module count = 11 × (symbols + start + check) + 13', () {
      // Set B, 5 characters -> 5 symbols.
      expect(Code128.encode('7XQ2K')!.length, 11 * (5 + 2) + 13);
      // Set C, 10 digits -> 5 digit-pair symbols.
      expect(Code128.encode('0012345678')!.length, 11 * (5 + 2) + 13);
      // Set B, 12 characters (an NRBE) -> 12 symbols.
      expect(Code128.encode('G00001234567')!.length, 11 * (12 + 2) + 13);
      // Set B, 16 characters (a tax code) -> 16 symbols.
      expect(Code128.encode('RSSMRA85T10A562S')!.length, 11 * (16 + 2) + 13);
    });

    test('characters outside ASCII 32-127 are refused', () {
      expect(Code128.encode('bad\ttab'), isNull); // tab = 9, below 32
      expect(Code128.encode('café'), isNull); // é is above 127
    });

    test('ASCII 32 (space) and 127 (DEL) are the edges of set B', () {
      expect(Code128.encode(' AAAA '), isNotNull);
      expect(Code128.encode('A\x7FA'), isNotNull);
    });
  });

  testWidgets('paints an encodable barcode without error', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: 2.5),
          child: SizedBox(width: 320, child: Code128Barcode('0410A1234567890')),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders nothing for data Code 128 cannot encode', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 320, child: Code128Barcode('café')),
      ),
    );
    expect(find.byType(SizedBox).evaluate().isNotEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a too-narrow screen never paints outside the widget (clipped)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 50, child: Code128Barcode('0410A1234567890')),
      ),
    );
    expect(find.byType(ClipRect), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('rendered barcode pixel runs', () {
    // The five pharmacy values calibrated in the phase C spec: the two SSN
    // NRE halves, a white NRBE, its PIN, and a patient tax code.
    const values = [
      '041A0',
      '0012345678',
      'G00001234567',
      '7XQ2K',
      'RSSMRA85T10A562S',
      // All digits, odd length: set B.
      '12345',
    ];
    const width = 360.0;
    const dpr = 3.0;

    /// Set to a directory (e.g. by the controller, outside CI) to also
    /// write each rendered barcode as a PNG there for an external decode
    /// check (zxing-cpp). The pixel-run assertions below always run.
    final pngDir = Platform.environment['MEDORA_BARCODE_PNG_DIR'];

    for (final value in values) {
      testWidgets('renders $value with whole-module pixel runs'
          '${pngDir == null ? '' : ' (writes PNG)'}', (tester) async {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: dpr),
              // Center: the test surface otherwise hands the root tight
              // constraints (its own full size), which would force the
              // barcode to stretch past the 360dp `width` this test's own
              // BarcodeLayout.layout call below assumes.
              child: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(width: width, child: Code128Barcode(value)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final modules = Code128.encode(value)!;
        final layout = BarcodeLayout.layout(
          width: width,
          dpr: dpr,
          modules: modules.length,
        );
        final modulePx = (layout.module * dpr).round();
        expect(modulePx, greaterThanOrEqualTo(1));

        // Capture at the same pixel ratio the widget laid itself out
        // with, so 1 captured pixel == 1 device pixel of the layout
        // math above (module widths land on whole captured pixels too).
        final capturedImage = await tester.runAsync(() {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          return boundary.toImage(pixelRatio: dpr);
        });
        final image = capturedImage!;
        final rawBytes = await tester.runAsync(image.toByteData);
        expect(rawBytes, isNotNull);
        final bytes = rawBytes!.buffer.asUint8List();
        final imageWidth = image.width;

        // Sample the row through the middle of the barcode's height.
        final barHeightPx = (96 * dpr).round(); // Code128Barcode height
        final containerHeightPx = image.height;
        final rowY = (containerHeightPx - barHeightPx) ~/ 2 + barHeightPx ~/ 2;

        bool isDark(int x) {
          final offset = (rowY * imageWidth + x) * 4;
          // isAntiAlias is off and colours are pure black/white, so a
          // simple threshold on the red channel is exact.
          return bytes[offset] < 128;
        }

        final leftPx = (layout.left * dpr).round();
        final totalPx = modules.length * modulePx;

        // Walk the bars/spaces within the barcode's own width (excluding
        // the white quiet zone, whose size is not a module multiple) and
        // check every run is a whole number of modules.
        var x = leftPx;
        final end = leftPx + totalPx;
        while (x < end) {
          final dark = isDark(x);
          final runStart = x;
          while (x < end && isDark(x) == dark) {
            x++;
          }
          final runLength = x - runStart;
          expect(
            runLength % modulePx,
            0,
            reason:
                '$value: run at $runStart..${x - 1} (dark=$dark) is '
                '$runLength px, not a multiple of module $modulePx px',
          );
        }

        if (pngDir != null) {
          final pngBytes = await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.png),
          );
          final dir = Directory(pngDir)..createSync(recursive: true);
          final safeName = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
          File(
            '${dir.path}/$safeName.png',
          ).writeAsBytesSync(pngBytes!.buffer.asUint8List());
        }
      });
    }
  });
}
