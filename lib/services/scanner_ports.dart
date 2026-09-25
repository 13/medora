/// Medora - the scanner's camera and recogniser seams
///
/// `BarcodeScannerScreen` drives a camera, a gallery picker and two ML Kit
/// detectors. All four are plugins that cannot run in a widget test, so the
/// screen talks to these interfaces instead and reads them from providers
/// (see `providers.dart`); the ML Kit / `camera` / `image_picker`
/// implementations live in `mlkit_scanner_ports.dart` and the fakes in
/// `test/helpers/fake_scanner_ports.dart`.
///
/// No plugin import belongs in this file: it is what the tests implement.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:medora/services/code_candidates.dart';

/// An image handed to a recogniser: a file on disk, or raw RGBA bytes.
sealed class ScanImage {
  const ScanImage();
}

/// An encoded image file (the photo itself, or a PNG crop of it).
final class ScanImageFile extends ScanImage {
  const ScanImageFile(this.path);

  final String path;

  @override
  String toString() => 'ScanImageFile($path)';
}

/// A decoded RGBA bitmap (the downscaled barcode retry).
final class ScanImageBitmap extends ScanImage {
  const ScanImageBitmap({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  @override
  String toString() => 'ScanImageBitmap(${width}x$height)';
}

/// Text recognition over a [ScanImage]; throws are the caller's to log.
abstract class TextRecognitionPort {
  /// The recognised lines, with boxes in the image's own pixels.
  Future<List<OcrLine>> linesIn(ScanImage image);

  /// Releases the detector. The provider closes it; the screen does not.
  Future<void> close();
}

/// Barcode decoding over a [ScanImage], already mapped to candidates.
abstract class BarcodeScanPort {
  /// The decoded barcodes as candidates, with boxes in the image's pixels.
  Future<List<CodeCandidate>> candidatesIn(ScanImage image);

  /// Releases the detector. The provider closes it; the screen does not.
  Future<void> close();
}

/// Barcode decoding over a [ScanImage] for prescription scanning: the raw
/// decoded values, with no mapping to a package's [CodeCandidate] — a
/// prescription's NRE, NRBE, PIN and tax codes are read from these strings
/// by `RxExtractor`, not from candidate ranking.
abstract class RawBarcodePort {
  /// The decoded values, in the order ML Kit found them.
  Future<List<String>> valuesIn(ScanImage image);

  /// Releases the detector. The caller closes it; nothing else does.
  Future<void> close();
}

/// The still camera the capture stage drives.
///
/// One instance survives [dispose]: the screen disposes the camera when the
/// app goes inactive and initialises the same port again on resume.
abstract class CameraPort {
  /// Opens the back camera. True once the preview is live, false when the
  /// device has no camera at all; throws when opening it failed.
  Future<bool> initialize();

  /// Whether the preview is live.
  bool get isReady;

  /// Whether a capture is in flight, so the shutter and the gallery button
  /// can be disabled. True from the moment [takePicture] is called.
  bool get isTakingPicture;

  /// The sensor preview size (always landscape); null until ready.
  Size? get previewSize;

  /// The preview widget, sized by the caller; empty until ready.
  Widget buildPreview(BuildContext context);

  /// Takes a photo and returns its path, or null when none was written.
  Future<String?> takePicture();

  /// Turns the torch on or off. False when the camera refused, so the
  /// caller can leave its torch indicator alone.
  Future<bool> setTorch(bool on);

  /// Focuses at a point in normalised (0..1) preview coordinates. Failures
  /// are logged, not thrown: not every device can focus on demand.
  Future<void> setFocusPoint(Offset normalized);

  /// Freezes the preview while a photo is reviewed.
  Future<void> pausePreview();

  /// Unfreezes it on retake.
  Future<void> resumePreview();

  /// Releases the camera. Safe to call twice, and [initialize] may follow.
  Future<void> dispose();
}

/// Picking a photo from the gallery; null when the user cancels.
abstract class GalleryPort {
  Future<String?> pickImage();
}
