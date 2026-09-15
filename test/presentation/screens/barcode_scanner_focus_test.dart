import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';

void main() {
  // Sensor preview sizes are landscape.
  const previewSize = Size(1920, 1080);

  Offset focus(Offset tap, Size viewport, Orientation orientation) =>
      BarcodeScannerScreen.focusPointFor(
        tap: tap,
        viewport: viewport,
        previewSize: previewSize,
        orientation: orientation,
      );

  void expectOffset(Offset actual, Offset expected) {
    expect(actual.dx, closeTo(expected.dx, 1e-9));
    expect(actual.dy, closeTo(expected.dy, 1e-9));
  }

  group('portrait', () {
    // Child 1080x1920 covering 400x600: scale 400/1080, height 711.1,
    // cropped 55.6 px top and bottom.
    const viewport = Size(400, 600);

    test('centre maps to the centre', () {
      expectOffset(
        focus(const Offset(200, 300), viewport, Orientation.portrait),
        const Offset(0.5, 0.5),
      );
    });

    test('accounts for the vertical crop', () {
      const scaledHeight = 1920 * (400 / 1080);
      const crop = (scaledHeight - 600) / 2;
      expectOffset(
        focus(const Offset(100, 0), viewport, Orientation.portrait),
        const Offset(0.25, crop / scaledHeight),
      );
    });

    test('clamps to 0..1', () {
      expectOffset(
        focus(const Offset(-10, 1000), viewport, Orientation.portrait),
        const Offset(0, 1),
      );
    });
  });

  group('landscape', () {
    // Child 1920x1080 (not swapped) covering 800x360: scale 800/1920,
    // height 450, cropped 45 px top and bottom.
    const viewport = Size(800, 360);

    test('accounts for the vertical crop without swapping axes', () {
      expectOffset(
        focus(const Offset(600, 45), viewport, Orientation.landscape),
        const Offset(0.75, 90 / 450),
      );
      expectOffset(
        focus(const Offset(200, 315), viewport, Orientation.landscape),
        const Offset(0.25, 360 / 450),
      );
    });

    test('accounts for a horizontal crop', () {
      // 1000x400 viewport: scale max(1000/1920, 400/1080) = 0.5208,
      // height 562.5 → crop 81.25; tap at the top-left corner.
      final p = focus(
        Offset.zero,
        const Size(1000, 400),
        Orientation.landscape,
      );
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(81.25 / 562.5, 1e-9));
    });

    test('a narrow landscape viewport crops horizontally', () {
      // 600x500: scale max(600/1920, 500/1080) = 0.46296, width 888.9,
      // cropped 144.4 px left and right.
      const scale = 500 / 1080;
      const scaledWidth = 1920 * scale;
      const crop = (scaledWidth - 600) / 2;
      final p = focus(
        const Offset(0, 250),
        const Size(600, 500),
        Orientation.landscape,
      );
      expectOffset(p, const Offset(crop / scaledWidth, 0.5));
    });
  });

  test('preview child size swaps only in portrait', () {
    expect(
      BarcodeScannerScreen.previewChildSize(previewSize, Orientation.portrait),
      const Size(1080, 1920),
    );
    expect(
      BarcodeScannerScreen.previewChildSize(previewSize, Orientation.landscape),
      previewSize,
    );
  });
}
