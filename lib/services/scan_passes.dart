/// The recognition passes over one photo: text, barcodes, the region crop,
/// the barcode stripes above the digits, and the downscaled retry.
///
/// Lifted out of `barcode_scanner_screen.dart`, which was 1384 lines and did
/// three unrelated things: drive the camera, recognise the photo, and route
/// what it found. This is the middle one. It holds no widget state — the two
/// plugin seams (`scanner_ports.dart`) and a [stale] predicate are all it
/// needs — so a pass can be exercised without pumping a screen.
///
/// Every pass answers rather than throws: a failure is logged and comes back
/// as null or empty, because the passes that did work are still worth
/// offering. [stale] is asked between passes and between rotations, so a
/// screen that is gone, or a photo that has been replaced, stops the work
/// instead of finishing it into nothing.
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/image_size.dart';
import 'package:medora/services/scan_debug.dart';
import 'package:medora/services/scan_region.dart';
import 'package:medora/services/scanner_ports.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Longer side of the downscaled copy for the second barcode pass.
const int kBarcodeRetryMaxSide = 1600;

/// How long decoding and rendering the region crop may take.
const Duration kRegionCropTimeout = Duration(seconds: 15);

/// How long the whole stripe pass may take, across every target and every
/// rotation of it.
const Duration kStripeTimeout = Duration(seconds: 15);

class ScanPasses {
  ScanPasses({
    required this.textPort,
    required this.barcodePort,
    required this.stale,
  });

  final TextRecognitionPort textPort;
  final BarcodeScanPort barcodePort;

  /// True once this work is pointless: the screen is gone, or the photo it
  /// was started for is no longer the one being recognised.
  final bool Function() stale;

  /// The OCR lines of [image], boxes mapped to the photo by [offset] (a
  /// crop's position in the photo) and [scale] (see [offsetOcrLines]); null
  /// (logged) when text recognition fails, so decoded barcodes can still be
  /// offered.
  Future<List<OcrLine>?> recognizeText(
    ScanImage image, {
    Offset offset = Offset.zero,
    double scale = 1.0,
    String? pass,
  }) async {
    try {
      final lines = offsetOcrLines(
        await textPort.linesIn(image),
        offset,
        scale: scale,
      );
      scanLog([
        '[scan] text lines${pass == null ? '' : ' ($pass)'}: ${lines.length}',
        ...describeOcrLines(lines),
      ]);
      return lines;
    } catch (e, stack) {
      debugPrint('[scan] text recognition failed: $e\n$stack');
      return null;
    }
  }

  /// Barcode candidates of [image]; null (logged) when scanning fails, so
  /// OCR results are still offered.
  Future<List<CodeCandidate>?> scanBarcodes(
    ScanImage image, {
    required String pass,
  }) async {
    try {
      // The port logs each decoded value, including those that map to no
      // candidate; the pass is only known here.
      final candidates = await barcodePort.candidatesIn(image);
      scanLog(['[scan] barcodes ($pass): ${candidates.length}']);
      return candidates;
    } catch (e, stack) {
      debugPrint('[scan] barcode scanning failed ($pass): $e\n$stack');
      return null;
    }
  }

  /// Text recognition and barcode scanning on the crop of the photo at
  /// [path] (of pixel [size]) around [boxes] (see [textRegionCrop]), with
  /// boxes mapped back to the photo. The crop is a PNG in a fresh directory
  /// under the app's temporary directory, deleted when done. Null when there
  /// is no useful crop, rendering it takes longer than [kRegionCropTimeout]
  /// (e.g. the raster thread stalls in the background) or the pass fails
  /// (logged); the first pass stands.
  Future<({List<OcrLine> lines, List<CodeCandidate> barcodes})?>
  recognizeRegion(String path, Size size, List<Rect> boxes) async {
    final crop = textRegionCrop(boxes, size);
    if (crop == null) return null;
    Directory? dir;
    try {
      dir = await (await getTemporaryDirectory()).createTemp('scan_region_');
      final out = p.join(dir.path, 'region.png');
      final written = await writeImageCrop(
        path,
        crop,
        out,
      ).timeout(kRegionCropTimeout);
      if (written == null) return null;
      final (crop: region, :scale) = written;
      scanLog([
        '[scan] region pass ${region.width.round()}x${region.height.round()} '
            '@ ${region.left.round()},${region.top.round()} scale $scale',
      ]);
      final input = ScanImageFile(out);
      final (lines, found) = await (
        recognizeText(
          input,
          offset: region.topLeft,
          scale: scale,
          pass: 'region',
        ),
        scanBarcodes(input, pass: 'region, crop pixels'),
      ).wait;
      return (
        lines: lines ?? const <OcrLine>[],
        barcodes: offsetCandidates(
          found ?? const [],
          region.topLeft,
          scale: scale,
        ),
      );
    } catch (e, stack) {
      debugPrint('[scan] region pass failed: $e\n$stack');
      return null;
    } finally {
      if (dir != null) await deleteDirectory(dir);
    }
  }

  /// A barcode pass on the bars above the digits OCR read: for each target
  /// (see [barcodeStripeTargets]) the crop is written as a PNG under the
  /// [regionMaxDecodeSide] cap at 0°, 90°, 180° and 270° — all four from a
  /// single decode of the photo (see [writeImageCropRotations]) — and
  /// scanned in that order, stopping at the first rotation that decodes.
  /// Boxes come back in photo pixels. The whole pass, targets included,
  /// gets [kStripeTimeout]; it also stops as soon as [stale] says so. Empty
  /// when nothing decodes, the crop times out or the pass fails (logged);
  /// the photo's own passes stand.
  Future<List<CodeCandidate>> scanBarcodeStripes(
    String path,
    Size size,
    List<CodeCandidate> candidates,
  ) async {
    final found = <CodeCandidate>[];
    final elapsed = Stopwatch()..start();
    Duration left() => kStripeTimeout - elapsed.elapsed;
    bool stop() => stale() || left() <= Duration.zero;
    for (final target in barcodeStripeTargets(candidates)) {
      if (stop()) break;
      final crop = barcodeStripeCrop(target, size);
      if (crop == null) continue;
      Directory? dir;
      try {
        dir = await (await getTemporaryDirectory()).createTemp('scan_stripe_');
        final rotations = [
          for (var turns = 0; turns < 4; turns++)
            (
              quarterTurns: turns,
              outPath: p.join(dir.path, 'stripe_$turns.png'),
            ),
        ];
        if (stop()) break;
        final written = await writeImageCropRotations(
          path,
          crop,
          rotations,
        ).timeout(left());
        if (written == null) break;
        for (final rotation in rotations) {
          if (stop()) break;
          final decoded = await scanBarcodes(
            ScanImageFile(rotation.outPath),
            pass: 'stripe ${rotation.quarterTurns * 90}°',
          );
          if (decoded == null || decoded.isEmpty) continue;
          found.addAll(
            unrotateCandidates(
              decoded,
              quarterTurns: rotation.quarterTurns,
              crop: written.crop,
              scale: written.scale,
            ),
          );
          break;
        }
      } catch (e, stack) {
        debugPrint('[scan] stripe pass failed: $e\n$stack');
      } finally {
        if (dir != null) await deleteDirectory(dir);
      }
      if (found.isNotEmpty) break;
    }
    return found;
  }

  /// A second barcode pass on a copy of the photo downscaled to
  /// [kBarcodeRetryMaxSide]: ML Kit can miss a small or angled barcode in a
  /// full-resolution photo. Boxes are scaled back to [size], the photo's
  /// pixels. Empty when the photo is small already or the pass fails.
  Future<List<CodeCandidate>> scanBarcodesDownscaled(
    String path,
    Size size,
  ) async {
    try {
      final small = await decodeDownscaledRgba(path, kBarcodeRetryMaxSide);
      if (small == null) return const [];
      final found = await scanBarcodes(
        ScanImageBitmap(
          rgba: small.rgba,
          width: small.width,
          height: small.height,
        ),
        pass: 'downscaled ${small.width}x${small.height}',
      );
      if (found == null || found.isEmpty) return const [];
      final sx = size.width / small.width;
      final sy = size.height / small.height;
      return [
        for (final c in found)
          CodeCandidate(
            code: c.code,
            kind: c.kind,
            sourceText: c.sourceText,
            box: Rect.fromLTRB(
              c.box.left * sx,
              c.box.top * sy,
              c.box.right * sx,
              c.box.bottom * sy,
            ),
          ),
      ];
    } catch (e, stack) {
      debugPrint('[scan] downscaled barcode pass failed: $e\n$stack');
      return const [];
    }
  }

  /// Removes a temporary crop directory. A crop that outlives its pass is a
  /// leak, not a failure: it is logged and the pass's result stands.
  Future<void> deleteDirectory(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('[scan] temporary crop not deleted: $e');
    }
  }
}
