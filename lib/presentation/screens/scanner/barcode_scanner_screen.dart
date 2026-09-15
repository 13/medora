/// Medora - AIC scanner: take a photo, then choose the code
///
/// Three stages: capture (camera preview, shutter, gallery, manual entry),
/// recognizing (ML Kit text recognition and barcode scanning run in parallel
/// on the still photo) and review (the photo with every detected code
/// numbered; the user taps the one to use). When the whole photo leaves
/// something to find (see `scan_region.dart`), text recognition and barcode
/// scanning run again on a temporary PNG crop around the text found, deleted
/// right after. Photos taken here are temporary
/// files, deleted on retake, when leaving the screen and in `dispose`.
/// Gallery picks are deleted the same way only when the picker handed us a
/// copy inside the app's temporary directory (Android copies picks into the
/// app cache); a path outside it could be the user's original and is never
/// touched.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/scanner/scan_result.dart';
import 'package:medora/presentation/screens/scanner/scan_review_view.dart';
import 'package:medora/presentation/screens/scanner/supplement_register_dialogs.dart';
import 'package:medora/presentation/screens/scanner/supplement_routing.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/barcode_adapter.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/image_size.dart';
import 'package:medora/services/ocr_adapter.dart';
import 'package:medora/services/scan_debug.dart';
import 'package:medora/services/scan_region.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class BarcodeScannerScreen extends ConsumerStatefulWidget {
  const BarcodeScannerScreen({super.key, this.returnBarcodeOnly = false});

  final bool returnBarcodeOnly;

  /// The laid-out size of the camera preview for a sensor [previewSize]
  /// (always landscape): portrait swaps width and height.
  static Size previewChildSize(Size previewSize, Orientation orientation) =>
      orientation == Orientation.portrait
      ? Size(previewSize.height, previewSize.width)
      : previewSize;

  /// The normalised (0..1) focus point for a [tap] in [viewport], where the
  /// preview is cover-fitted (centred, cropped on the overflowing axis).
  @visibleForTesting
  static Offset focusPointFor({
    required Offset tap,
    required Size viewport,
    required Size previewSize,
    required Orientation orientation,
  }) {
    final child = previewChildSize(previewSize, orientation);
    if (child.isEmpty || viewport.isEmpty) return const Offset(0.5, 0.5);
    final scale = math.max(
      viewport.width / child.width,
      viewport.height / child.height,
    );
    final dx = (viewport.width - child.width * scale) / 2;
    final dy = (viewport.height - child.height * scale) / 2;
    return Offset(
      ((tap.dx - dx) / (child.width * scale)).clamp(0.0, 1.0),
      ((tap.dy - dy) / (child.height * scale)).clamp(0.0, 1.0),
    );
  }

  @override
  ConsumerState<BarcodeScannerScreen> createState() =>
      _BarcodeScannerScreenState();
}

enum _ScanStage { capture, recognizing, review }

class _BarcodeScannerScreenState extends ConsumerState<BarcodeScannerScreen>
    with WidgetsBindingObserver {
  static const Color _onScrim = Color(0xFFFFFFFF); // on scrim

  CameraController? _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();
  final BarcodeScanner _barcodeScanner = BarcodeScanner(
    formats: scanBarcodeFormats,
  );

  _ScanStage _stage = _ScanStage.capture;
  bool _isSearching = false;
  bool _picking = false;
  bool _isCameraReady = false;
  bool _cameraFailed = false;
  bool _torchOn = false;

  /// The photo being recognised or reviewed.
  String? _photoPath;

  /// Whether [_photoPath] is a camera capture we own (deleted when done).
  bool _photoIsTemp = false;
  Size _imageSize = Size.zero;
  List<CodeCandidate> _candidates = const [];

  /// The width the photo is decoded at for display (see [_photoImage]).
  int? _photoDecodeWidth;

  /// Longer side of the downscaled copy for the second barcode pass.
  static const int _barcodeRetryMaxSide = 1600;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (state == AppLifecycleState.inactive) {
      if (controller == null) return;
      _cameraController = null;
      _torchOn = false;
      if (mounted) setState(() => _isCameraReady = false);
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // Review keeps the photo; the camera comes back on retake.
      if (_stage == _ScanStage.capture && controller == null) {
        _initializeCamera();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _textRecognizer.close();
    _barcodeScanner.close();
    _discardPhoto();
    super.dispose();
  }

  // ── Camera ─────────────────────────────────────────────────

  Future<void> _initializeCamera() async {
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted) return;
      if (cameras.isEmpty) {
        setState(() => _cameraFailed = true);
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      controller = CameraController(
        backCamera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _cameraController = controller;
      await controller.initialize();
      if (!mounted || _cameraController != controller) return;
      try {
        await controller.setFocusMode(FocusMode.auto);
      } on CameraException catch (e) {
        debugPrint('Camera focus mode unsupported: $e');
      }
      if (!mounted || _cameraController != controller) return;
      setState(() {
        _isCameraReady = true;
        _cameraFailed = false;
      });
      // Re-initialised while a photo was being recognised or reviewed (e.g.
      // the gallery picker paused the app): keep the preview paused.
      if (_stage != _ScanStage.capture) await _pausePreview();
    } catch (e) {
      debugPrint('Camera init error: $e');
      // A newer initialisation (or a lifecycle pause) replaced this one.
      if (!mounted || _cameraController != controller) return;
      setState(() {
        _isCameraReady = false;
        _cameraFailed = true;
      });
      _showError();
    }
  }

  /// Focuses at [local], a point in the cover-fitted preview of [viewport].
  Future<void> _focusAt(
    Offset local,
    Size viewport,
    Orientation orientation,
  ) async {
    final controller = _cameraController;
    final previewSize = controller?.value.previewSize;
    if (controller == null || !_isCameraReady || previewSize == null) return;
    final point = BarcodeScannerScreen.focusPointFor(
      tap: local,
      viewport: viewport,
      previewSize: previewSize,
      orientation: orientation,
    );
    try {
      await controller.setFocusPoint(point);
    } on CameraException catch (e) {
      debugPrint('Camera focus point unsupported: $e');
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _cameraController;
    if (controller == null) return;
    try {
      await controller.setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      if (mounted) setState(() => _torchOn = !_torchOn);
    } on CameraException catch (e) {
      debugPrint('Torch error: $e');
    }
  }

  Future<void> _pausePreview() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (_torchOn) {
        await controller.setFlashMode(FlashMode.off);
        _torchOn = false;
      }
      await controller.pausePreview();
    } on CameraException catch (e) {
      debugPrint('Camera pause error: $e');
    }
  }

  Future<void> _resumePreview() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _cameraController = null;
      await _initializeCamera();
      return;
    }
    try {
      await controller.resumePreview();
    } on CameraException catch (e) {
      debugPrint('Camera resume error: $e');
    }
  }

  // ── Capture → recognize ────────────────────────────────────

  Future<void> _takePhoto() async {
    final controller = _cameraController;
    if (controller == null ||
        !_isCameraReady ||
        _stage != _ScanStage.capture ||
        controller.value.isTakingPicture) {
      return;
    }
    try {
      final capture = controller.takePicture();
      // isTakingPicture is now true: disable gallery and manual entry.
      setState(() {});
      final file = await capture;
      if (!mounted) {
        unawaited(_deleteFile(file.path));
        return;
      }
      await _recognize(file.path, isTemp: true);
    } catch (e) {
      debugPrint('Take picture error: $e');
      if (mounted) {
        setState(() {});
        _showError();
      }
    }
  }

  bool get _isTakingPicture =>
      _cameraController?.value.isTakingPicture ?? false;

  Future<void> _pickFromGallery() async {
    if (_stage != _ScanStage.capture || _picking || _isTakingPicture) return;
    setState(() => _picking = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      final isCacheCopy = await _isInTemporaryDirectory(picked.path);
      if (!mounted) {
        if (isCacheCopy) unawaited(_deleteFile(picked.path));
        return;
      }
      await _recognize(picked.path, isTemp: isCacheCopy);
    } catch (e) {
      debugPrint('Gallery pick error: $e');
      if (mounted) _showError();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Whether [path] is a picker copy in the app's temporary directory (safe
  /// to delete) rather than a user's original file.
  Future<bool> _isInTemporaryDirectory(String path) async {
    try {
      final temp = await getTemporaryDirectory();
      return p.isWithin(p.canonicalize(temp.path), p.canonicalize(path));
    } catch (e) {
      debugPrint('Temporary directory unavailable: $e');
      return false;
    }
  }

  Future<void> _recognize(String path, {required bool isTemp}) async {
    // A photo still held (a capture and a gallery pick that overlapped) is
    // deleted before this one replaces it.
    if (_photoPath != path) _discardPhoto();
    setState(() {
      _stage = _ScanStage.recognizing;
      _photoPath = path;
      _photoIsTemp = isTemp;
      _candidates = const [];
    });
    await _pausePreview();
    if (!mounted) return;
    try {
      final input = InputImage.fromFilePath(path);
      final (lines, photoBarcodes, size) = await (
        _recognizeText(input),
        _scanBarcodes(input, pass: 'photo'),
        readImageSize(path),
      ).wait;
      if (!mounted || _photoPath != path) return;
      if (lines == null && photoBarcodes == null) {
        throw StateError('Text recognition and barcode scanning failed');
      }
      var barcodes = photoBarcodes ?? const <CodeCandidate>[];
      if (barcodes.isEmpty) {
        barcodes = await _scanBarcodesDownscaled(path, size);
        if (!mounted || _photoPath != path) return;
      }
      var allLines = lines ?? const <OcrLine>[];
      var candidates = findCodeCandidates(allLines, barcodes: barcodes);
      if (needsRegionPass(
        lines: allLines,
        barcodes: barcodes,
        candidates: candidates,
      )) {
        final region = await _recognizeRegion(path, size, [
          for (final line in allLines) line.box,
          for (final barcode in barcodes) barcode.box,
        ]);
        if (!mounted || _photoPath != path) return;
        if (region != null) {
          allLines = [...allLines, ...region.lines];
          barcodes = [...barcodes, ...region.barcodes];
          candidates = findCodeCandidates(allLines, barcodes: barcodes);
        }
      }
      scanLog([
        '[scan] image: ${size.width.round()}x${size.height.round()}',
        ...describeCandidates(candidates),
      ]);
      setState(() {
        _imageSize = size;
        _candidates = candidates;
        _stage = _ScanStage.review;
      });
    } catch (e) {
      debugPrint('Recognition error: $e');
      if (!mounted) return;
      _showError();
      await _retake();
    }
  }

  /// The OCR lines of [input], boxes moved by [offset] (a crop's position in
  /// the photo); null (logged) when text recognition fails, so decoded
  /// barcodes can still be offered.
  Future<List<OcrLine>?> _recognizeText(
    InputImage input, {
    Offset offset = Offset.zero,
    String? pass,
  }) async {
    try {
      final lines = offsetOcrLines(
        ocrLinesFrom(await _textRecognizer.processImage(input)),
        offset,
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

  /// Barcode candidates of [input]; null (logged) when scanning fails, so
  /// OCR results are still offered.
  Future<List<CodeCandidate>?> _scanBarcodes(
    InputImage input, {
    required String pass,
  }) async {
    try {
      final barcodes = await _barcodeScanner.processImage(input);
      scanLog([
        '[scan] barcodes ($pass): ${barcodes.length}',
        ...describeBarcodes(barcodes),
      ]);
      return barcodeCandidatesFrom(barcodes);
    } catch (e, stack) {
      debugPrint('[scan] barcode scanning failed ($pass): $e\n$stack');
      return null;
    }
  }

  /// Text recognition and barcode scanning on the crop of the photo at
  /// [path] (of pixel [size]) around [boxes] (see [textRegionCrop]), with
  /// boxes mapped back to the photo. The crop is a PNG in a fresh directory
  /// under the app's temporary directory, deleted when done. Null when there
  /// is no useful crop or the pass fails (logged); the first pass stands.
  Future<({List<OcrLine> lines, List<CodeCandidate> barcodes})?>
  _recognizeRegion(String path, Size size, List<Rect> boxes) async {
    final crop = textRegionCrop(boxes, size);
    if (crop == null) return null;
    Directory? dir;
    try {
      dir = await (await getTemporaryDirectory()).createTemp('scan_region_');
      final out = p.join(dir.path, 'region.png');
      final written = await writeImageCrop(path, crop, out);
      if (written == null) return null;
      scanLog([
        '[scan] region pass ${written.width.round()}x${written.height.round()} '
            '@ ${written.left.round()},${written.top.round()}',
      ]);
      final input = InputImage.fromFilePath(out);
      final (lines, found) = await (
        _recognizeText(input, offset: written.topLeft, pass: 'region'),
        _scanBarcodes(input, pass: 'region, crop pixels'),
      ).wait;
      return (
        lines: lines ?? const <OcrLine>[],
        barcodes: offsetCandidates(found ?? const [], written.topLeft),
      );
    } catch (e, stack) {
      debugPrint('[scan] region pass failed: $e\n$stack');
      return null;
    } finally {
      if (dir != null) await _deleteDirectory(dir);
    }
  }

  Future<void> _deleteDirectory(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('[scan] temporary crop not deleted: $e');
    }
  }

  /// A second barcode pass on a copy of the photo downscaled to
  /// [_barcodeRetryMaxSide]: ML Kit can miss a small or angled barcode in a
  /// full-resolution photo. Boxes are scaled back to [size], the photo's
  /// pixels. Empty when the photo is small already or the pass fails.
  Future<List<CodeCandidate>> _scanBarcodesDownscaled(
    String path,
    Size size,
  ) async {
    try {
      final small = await decodeDownscaledRgba(path, _barcodeRetryMaxSide);
      if (small == null) return const [];
      final found = await _scanBarcodes(
        InputImage.fromBitmap(
          bitmap: small.rgba,
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

  /// The photo at [path] decoded at twice the screen width in physical
  /// pixels instead of the full camera resolution. Markers are placed from
  /// [_imageSize] (the file's pixel size), so the decode size does not move
  /// them.
  ImageProvider _photoImage(String path) {
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context) *
                2)
            .round();
    _photoDecodeWidth = width;
    return ResizeImage(FileImage(File(path)), width: width);
  }

  Future<void> _retake() async {
    _discardPhoto();
    setState(() {
      _candidates = const [];
      _imageSize = Size.zero;
      _stage = _ScanStage.capture;
    });
    await _resumePreview();
  }

  /// Forgets the current photo, deleting it if the camera took it.
  void _discardPhoto() {
    final path = _photoPath;
    if (path != null) {
      // Drop the decoded photo from the image cache.
      final file = FileImage(File(path));
      unawaited(file.evict());
      final width = _photoDecodeWidth;
      if (width != null) unawaited(ResizeImage(file, width: width).evict());
    }
    if (path != null && _photoIsTemp) unawaited(_deleteFile(path));
    _photoPath = null;
    _photoIsTemp = false;
  }

  Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  void _showError() {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.genericError)));
  }

  // ── Selection ──────────────────────────────────────────────

  void _onCandidateSelected(CodeCandidate candidate) {
    if (_isSearching) return;
    if (widget.returnBarcodeOnly) {
      _handleCode(candidate.code, kind: candidate.kind);
      return;
    }
    switch (candidate.kind) {
      case CodeKind.aic:
        _handleCode(candidate.code);
      case CodeKind.supplement:
        _openSupplement(candidate);
      case CodeKind.ean:
        _openEan(candidate);
      case CodeKind.other:
        _leaveAndPush(addMedicationWithBarcode(candidate.code));
    }
  }

  /// Looks the code up in the food-supplement register (offering the
  /// first download), then opens Add Medication prefilled, a picker for
  /// several products, or Add Medication with just the code.
  Future<void> _openSupplement(CodeCandidate candidate) async {
    final code = candidate.code;
    if (!ref.read(platformCapabilitiesProvider).hasSupplementRegister) {
      _leaveAndPush(addMedicationWithBarcode(code));
      return;
    }
    final l10n = AppLocalizations.of(context);
    final service = ref.read(supplementRegistryServiceProvider);
    setState(() => _isSearching = true);
    try {
      if (!await service.hasData()) {
        if (!mounted) return;
        setState(() => _isSearching = false);
        final downloaded = await confirmAndDownloadSupplementRegister(
          context,
          service,
        );
        if (!mounted || downloaded == null) return; // cancelled
        if (!downloaded) {
          _showError(); // offline or the download failed
          return;
        }
        setState(() => _isSearching = true);
      }
      final matches = await service.findByCode(code);
      if (!mounted) return;
      setState(() => _isSearching = false);
      switch (supplementRouteFor(matches)) {
        case SupplementPrefill(:final entry):
          _selectSupplement(entry, code);
        case SupplementPick(:final entries):
          final picked = await showSupplementPicker(context, entries);
          if (picked != null && mounted) _selectSupplement(picked, code);
        case SupplementNotFound():
          _leaveAndPush(
            addMedicationWithBarcode(code),
            message: l10n.supplementNotFound,
          );
      }
    } catch (e) {
      debugPrint('Supplement register lookup error: $e');
      if (!mounted) return;
      setState(() => _isSearching = false);
      _showError();
    }
  }

  void _selectSupplement(SupplementEntry entry, String code) {
    final l10n = AppLocalizations.of(context);
    _leaveAndPush(
      addMedicationWithBarcode(code),
      message: l10n.autoFilledFromBarcode,
      extra: entry,
    );
  }

  /// The cabinet medication with this barcode, else Add Medication.
  Future<void> _openEan(CodeCandidate candidate) async {
    setState(() => _isSearching = true);
    final l10n = AppLocalizations.of(context);
    try {
      final result = await ref
          .read(medicationRepositoryProvider)
          .getMedicationByBarcode(candidate.code);
      if (!mounted) return;
      setState(() => _isSearching = false);
      if (result.isFailure) {
        _showError();
        return;
      }
      final medication = result.dataOrNull;
      if (medication != null) {
        _leaveAndPush(
          AppRoutes.medicationDetail.replaceFirst(':id', medication.id),
          message: l10n.scanMedicationInCabinet,
        );
      } else {
        _leaveAndPush(addMedicationWithBarcode(candidate.code));
      }
    } catch (e) {
      debugPrint('Cabinet barcode lookup error: $e');
      if (!mounted) return;
      setState(() => _isSearching = false);
      _showError();
    }
  }

  /// Replaces the scanner (its photo is deleted in `dispose`) with
  /// [location], optionally with a snackbar [message].
  void _leaveAndPush(String location, {String? message, Object? extra}) {
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
    context.pushReplacement(location, extra: extra);
  }

  // ── UI ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scanBarcodeTitle),
        actions: [
          if (_stage == _ScanStage.capture && _isCameraReady)
            IconButton(
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              onPressed: _toggleTorch,
            ),
        ],
      ),
      body: switch (_stage) {
        _ScanStage.capture => _buildCapture(l10n),
        _ScanStage.recognizing => _buildRecognizing(l10n),
        _ScanStage.review => SafeArea(
          top: false,
          child: ScanReviewView(
            image: _photoImage(_photoPath!),
            imageSize: _imageSize,
            candidates: _candidates,
            onSelected: _onCandidateSelected,
            onRetake: _retake,
            onManualEntry: () => _showManualEntryDialog(context),
            busy: _isSearching,
          ),
        ),
      },
    );
  }

  Widget _buildCapture(AppLocalizations l10n) {
    final controller = _cameraController;
    final previewSize = controller?.value.previewSize;
    final busy = _isSearching || _picking || _isTakingPicture;
    final canShoot = _isCameraReady && controller != null && !busy;
    return ColoredBox(
      color: Colors.black, // scrim
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_isCameraReady && controller != null && previewSize != null)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final orientation = MediaQuery.orientationOf(context);
                      final child = BarcodeScannerScreen.previewChildSize(
                        previewSize,
                        orientation,
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _focusAt(
                          details.localPosition,
                          constraints.biggest,
                          orientation,
                        ),
                        child: SizedBox.expand(
                          child: ClipRect(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: child.width,
                                height: child.height,
                                child: CameraPreview(controller),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  )
                else if (!_cameraFailed)
                  const Center(
                    child: CircularProgressIndicator(color: _onScrim),
                  ),
                Positioned(
                  bottom: 12,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: _ScrimLabel(
                      child: _isSearching
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _onScrim,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  l10n.lookingUpBarcode,
                                  style: const TextStyle(
                                    color: _onScrim,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              l10n.scanCaptureHint,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _onScrim,
                                fontSize: 13,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    iconSize: 28,
                    color: _onScrim,
                    tooltip: l10n.scanFromGallery,
                    onPressed: busy ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  Tooltip(
                    message: l10n.scanTakePhoto,
                    child: FilledButton(
                      onPressed: canShoot ? _takePhoto : null,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        fixedSize: const Size(72, 72),
                        padding: EdgeInsets.zero,
                        disabledBackgroundColor: context.colors.onSurface
                            .withValues(alpha: 0.38),
                      ),
                      child: Icon(
                        Icons.camera_alt,
                        size: 32,
                        semanticLabel: l10n.scanTakePhoto,
                      ),
                    ),
                  ),
                  IconButton(
                    iconSize: 28,
                    color: _onScrim,
                    tooltip: l10n.enterBarcodeManually,
                    onPressed: busy
                        ? null
                        : () => _showManualEntryDialog(context),
                    icon: const Icon(Icons.keyboard),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecognizing(AppLocalizations l10n) {
    final path = _photoPath;
    return ColoredBox(
      color: Colors.black, // scrim
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (path != null)
            Image(
              image: _photoImage(path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.54)), // scrim
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: _onScrim),
                const SizedBox(height: 16),
                Text(
                  l10n.scanRecognizing,
                  style: const TextStyle(color: _onScrim, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Code lookup ────────────────────────────────────────────

  /// Looks [rawCode] up in AIFA, or in return-only mode pops it with its
  /// [kind] as a [ScanResult].
  Future<void> _handleCode(
    String rawCode, {
    CodeKind kind = CodeKind.aic,
  }) async {
    if (_isSearching) return;
    setState(() => _isSearching = true);

    if (widget.returnBarcodeOnly) {
      if (mounted) context.pop(ScanResult(rawCode, kind));
      return;
    }

    final l10n = AppLocalizations.of(context);
    try {
      final results = await AifaCacheService.instance.search(rawCode);
      if (!mounted) return;
      setState(() => _isSearching = false);

      if (results.isEmpty) {
        // Stay on the photo so another code can be picked.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.barcodeNotFound)));
        return;
      }

      if (results.length == 1) {
        await _selectResult(results.first, rawCode);
      } else {
        await _showResultPicker(results, rawCode);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.barcodeNotFound)));
      }
    }
  }

  Future<void> _showResultPicker(
    List<AifaSearchResult> results,
    String code,
  ) async {
    final l10n = AppLocalizations.of(context);

    final selected = await showModalBottomSheet<AifaSearchResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: ctx.colors.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.medication_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.selectMedication,
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${results.length} ${l10n.results}',
                    style: TextStyle(
                      color: ctx.colors.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                itemCount: results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = results[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: ctx.colors.primaryContainer,
                      child: Icon(
                        Icons.medication,
                        color: ctx.colors.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.description,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (r.activeIngredient != null)
                          Text(
                            r.activeIngredient!,
                            style: TextStyle(
                              fontSize: 11,
                              color: ctx.colors.onSurfaceVariant,
                            ),
                          ),
                        if (r.manufacturer != null)
                          Text(
                            r.manufacturer!,
                            style: TextStyle(
                              fontSize: 11,
                              color: ctx.colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(ctx, r),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (selected != null && mounted) {
      await _selectResult(selected, code);
    }
  }

  Future<void> _selectResult(AifaSearchResult result, String code) async {
    final l10n = AppLocalizations.of(context);
    _leaveAndPush(
      addMedicationWithBarcode(code),
      message: l10n.autoFilledFromBarcode,
      extra: result,
    );
  }

  void _showManualEntryDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.enterBarcode),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: l10n.barcodeNumber,
            hintText: 'A023834118',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(ctx);
                final codes = BarcodeLookupDatasource.extractCodes(value);
                final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
                if (codes.isNotEmpty) {
                  _handleCode(codes.first);
                } else if (isValidEan(digits)) {
                  _handleCode(digits, kind: CodeKind.ean);
                } else {
                  _handleCode(value, kind: CodeKind.other);
                }
              }
            },
            child: Text(l10n.useBarcode),
          ),
        ],
      ),
    );
  }
}

class _ScrimLabel extends StatelessWidget {
  const _ScrimLabel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.54), // scrim
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}
