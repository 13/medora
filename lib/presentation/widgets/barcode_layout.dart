/// Medora - Shared pixel-snapped layout for the linear barcodes printed on
/// an Italian prescription (Code 39, Code 128): the quiet zone a real
/// scanner needs, sized in from the start rather than carved out of a
/// module picked to fill the whole width, and the run-length collapsing
/// that lets the painter draw one rect per bar instead of one per module.
library;

import 'dart:math' show max;

abstract final class BarcodeLayout {
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
