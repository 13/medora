/// Medora - the real camera and ML Kit behind the scanner's ports
///
/// The only place that binds `camera`, `image_picker` and both ML Kit
/// plugins to the scanner. `scanner_ports.dart` holds the interfaces; this
/// file holds the implementations `providers.dart` wires up, so a widget
/// test can swap in fakes without a plugin in sight.
library;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/services/barcode_adapter.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/ocr_adapter.dart';
import 'package:medora/services/scan_debug.dart';
import 'package:medora/services/scanner_ports.dart';

/// The ML Kit input for a [ScanImage].
InputImage _inputImage(ScanImage image) => switch (image) {
  ScanImageFile(:final path) => InputImage.fromFilePath(path),
  ScanImageBitmap(:final rgba, :final width, :final height) =>
    InputImage.fromBitmap(bitmap: rgba, width: width, height: height),
};

/// [TextRecognitionPort] on ML Kit's on-device text recogniser.
class MlKitTextRecognitionPort implements TextRecognitionPort {
  final TextRecognizer _recognizer = TextRecognizer();

  @override
  Future<List<OcrLine>> linesIn(ScanImage image) async =>
      ocrLinesFrom(await _recognizer.processImage(_inputImage(image)));

  @override
  Future<void> close() => _recognizer.close();
}

/// [BarcodeScanPort] on ML Kit's barcode scanner, restricted to the formats
/// a package photo carries ([scanBarcodeFormats]).
class MlKitBarcodeScanPort implements BarcodeScanPort {
  final BarcodeScanner _scanner = BarcodeScanner(formats: scanBarcodeFormats);

  @override
  Future<List<CodeCandidate>> candidatesIn(ScanImage image) async {
    final barcodes = await _scanner.processImage(_inputImage(image));
    // Every decoded value, including those that map to no candidate.
    scanLog(describeBarcodes(barcodes));
    return barcodeCandidatesFrom(barcodes);
  }

  @override
  Future<void> close() => _scanner.close();
}

/// [CameraPort] on a `camera` [CameraController] for the back camera.
class CameraControllerPort implements CameraPort {
  CameraController? _controller;

  /// Set the moment a capture starts, so the shutter can be disabled before
  /// the plugin's own flag comes back.
  bool _takingPicture = false;

  @override
  bool get isReady => _controller?.value.isInitialized ?? false;

  @override
  bool get isTakingPicture =>
      _takingPicture || (_controller?.value.isTakingPicture ?? false);

  @override
  Size? get previewSize => _controller?.value.previewSize;

  @override
  Future<bool> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return false;
    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      backCamera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;
    await controller.initialize();
    // A newer initialisation (or a dispose) replaced this one.
    if (_controller != controller) return false;
    try {
      await controller.setFocusMode(FocusMode.auto);
    } on CameraException catch (e) {
      debugPrint('Camera focus mode unsupported: $e');
    }
    return _controller == controller;
  }

  @override
  Widget buildPreview(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  @override
  Future<String?> takePicture() async {
    final controller = _controller;
    if (controller == null) return null;
    _takingPicture = true;
    try {
      return (await controller.takePicture()).path;
    } finally {
      _takingPicture = false;
    }
  }

  @override
  Future<bool> setTorch(bool on) async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      await controller.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      return true;
    } on CameraException catch (e) {
      debugPrint('Torch error: $e');
      return false;
    }
  }

  @override
  Future<void> setFocusPoint(Offset normalized) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setFocusPoint(normalized);
    } on CameraException catch (e) {
      debugPrint('Camera focus point unsupported: $e');
    }
  }

  @override
  Future<void> pausePreview() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.pausePreview();
    } on CameraException catch (e) {
      debugPrint('Camera pause error: $e');
    }
  }

  @override
  Future<void> resumePreview() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.resumePreview();
    } on CameraException catch (e) {
      debugPrint('Camera resume error: $e');
    }
  }

  @override
  Future<void> dispose() async {
    final controller = _controller;
    _controller = null;
    _takingPicture = false;
    await controller?.dispose();
  }
}

/// [GalleryPort] on `image_picker`.
class ImagePickerGalleryPort implements GalleryPort {
  final ImagePicker _picker = ImagePicker();

  @override
  Future<String?> pickImage() async =>
      (await _picker.pickImage(source: ImageSource.gallery))?.path;
}
