/// Medora - OCR Scanner Screen
///
/// Uses the camera + Google ML Kit Text Recognition to read text
/// from medication packages. User can tap any detected text block
/// to use it as an AIC code for AIFA database lookup.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/aifa_cache_service.dart';

class BarcodeScannerScreen extends ConsumerStatefulWidget {
  const BarcodeScannerScreen({super.key, this.returnBarcodeOnly = false});

  final bool returnBarcodeOnly;

  @override
  ConsumerState<BarcodeScannerScreen> createState() =>
      _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends ConsumerState<BarcodeScannerScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer();

  bool _isSearching = false;
  bool _isProcessingFrame = false;
  bool _isCameraReady = false;
  bool _torchOn = false;
  bool _isPaused = false; // pause OCR when user is reviewing text

  /// All distinct text blocks detected by OCR, newest first.
  /// Each entry is a cleaned text line from OCR.
  final List<String> _detectedTexts = [];

  /// AIC-pattern codes found (subset of _detectedTexts that match pattern).
  final Set<String> _aicCodes = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty || !mounted) return;

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _isCameraReady = true);
      _cameraController!.startImageStream(_processImageStream);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  // ── OCR Processing ─────────────────────────────────────────

  void _processImageStream(CameraImage image) {
    if (_isProcessingFrame || _isSearching || _isPaused) return;
    _isProcessingFrame = true;

    // Process in a microtask to not block the camera stream
    Future.delayed(const Duration(milliseconds: 600), () async {
      try {
        if (!mounted || _isPaused) return;
        await _processOcrFrame(image);
      } catch (_) {
        // Ignore OCR errors silently
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  Future<void> _processOcrFrame(CameraImage image) async {
    if (!mounted) return;

    final camera = _cameraController?.description;
    if (camera == null) return;

    final inputImage = _convertCameraImage(image, camera.sensorOrientation);
    if (inputImage == null) return;

    final recognizedText = await _textRecognizer.processImage(inputImage);

    if (!mounted) return;

    // Collect all text blocks
    final newTexts = <String>{};
    final newAicCodes = <String>{};

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.length < 3) continue; // skip tiny fragments

        newTexts.add(text);

        // Check if this line contains AIC-like codes
        final codes = BarcodeLookupDatasource.extractCodes(text);
        newAicCodes.addAll(codes);
      }
    }

    if (newTexts.isNotEmpty && mounted) {
      setState(() {
        // Add new texts we haven't seen before
        for (final t in newTexts) {
          if (!_detectedTexts.contains(t)) {
            _detectedTexts.insert(0, t); // newest first
          }
        }
        _aicCodes.addAll(newAicCodes);

        // Keep list manageable (max 30 entries)
        if (_detectedTexts.length > 30) {
          _detectedTexts.removeRange(30, _detectedTexts.length);
        }
      });
    }
  }

  InputImage? _convertCameraImage(CameraImage image, int sensorOrientation) {
    final bytes = _concatenatePlanes(image.planes);
    if (bytes.isEmpty) return null;

    final rotation = _rotationFromSensorOrientation(sensorOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    int totalBytes = 0;
    for (final plane in planes) {
      totalBytes += plane.bytes.length;
    }
    final result = Uint8List(totalBytes);
    int offset = 0;
    for (final plane in planes) {
      result.setRange(offset, offset + plane.bytes.length, plane.bytes);
      offset += plane.bytes.length;
    }
    return result;
  }

  InputImageRotation _rotationFromSensorOrientation(int orientation) {
    return switch (orientation) {
      0 => InputImageRotation.rotation0deg,
      90 => InputImageRotation.rotation90deg,
      180 => InputImageRotation.rotation180deg,
      270 => InputImageRotation.rotation270deg,
      _ => InputImageRotation.rotation0deg,
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  // ── UI ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scanBarcodeTitle),
        actions: [
          if (_detectedTexts.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear',
              onPressed: () => setState(() {
                _detectedTexts.clear();
                _aicCodes.clear();
              }),
            ),
          if (_isCameraReady)
            IconButton(
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              onPressed: () async {
                await _cameraController?.setFlashMode(
                    _torchOn ? FlashMode.off : FlashMode.torch);
                setState(() => _torchOn = !_torchOn);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Camera preview — top half
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                if (_isCameraReady && _cameraController != null)
                  SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width:
                            _cameraController!.value.previewSize!.height,
                        height:
                            _cameraController!.value.previewSize!.width,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  )
                else
                  const Center(child: CircularProgressIndicator()),

                // Status overlay
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: _isSearching
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(l10n.lookingUpBarcode,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13)),
                              ],
                            )
                          : Text(
                              l10n.pointCameraAtBarcode,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Detected text blocks — bottom half, scrollable
          Expanded(
            flex: 2,
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.text_fields,
                            size: 18, color: Colors.grey[600]),
                        const SizedBox(width: 6),
                        Text(
                          l10n.ocrDetectedCodes,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600],
                          ),
                        ),
                        const Spacer(),
                        // Manual entry — icon only
                        IconButton(
                          icon: const Icon(Icons.keyboard, size: 20),
                          tooltip: l10n.enterBarcodeManually,
                          onPressed: _isSearching
                              ? null
                              : () => _showManualEntryDialog(context),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Text list
                  Expanded(
                    child: _detectedTexts.isEmpty
                        ? Center(
                            child: Text(
                              l10n.ocrScanning,
                              style: TextStyle(
                                  color: Colors.grey[400], fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            itemCount: _detectedTexts.length,
                            itemBuilder: (context, index) {
                              final text = _detectedTexts[index];
                              final isAic = _aicCodes.any((code) =>
                                  text.contains(code) ||
                                  text.replaceAll(
                                          RegExp(r'[^0-9]'), '') ==
                                      code);

                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Material(
                                  color: isAic
                                      ? AppTheme.primaryColor
                                          .withValues(alpha: 0.1)
                                      : null,
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: _isSearching
                                        ? null
                                        : () => _onTextSelected(text),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                      child: Row(
                                        children: [
                                          if (isAic)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 8),
                                              child: Icon(
                                                Icons.medication,
                                                size: 16,
                                                color:
                                                    AppTheme.primaryColor,
                                              ),
                                            ),
                                          Expanded(
                                            child: Text(
                                              text,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: isAic
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                                color: isAic
                                                    ? AppTheme.primaryColor
                                                    : null,
                                              ),
                                            ),
                                          ),
                                          Icon(Icons.chevron_right,
                                              size: 18,
                                              color: Colors.grey[400]),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────

  /// User tapped a detected text block.
  void _onTextSelected(String text) {
    // Try to extract an AIC code from the text
    final codes = BarcodeLookupDatasource.extractCodes(text);
    final code = codes.isNotEmpty ? codes.first : text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    _handleCode(code);
  }

  Future<void> _handleCode(String rawCode) async {
    if (_isSearching) return;

    // Pause OCR while searching
    setState(() {
      _isPaused = true;
      _isSearching = true;
    });

    if (widget.returnBarcodeOnly) {
      if (mounted) context.pop(rawCode);
      return;
    }

    final l10n = AppLocalizations.of(context);

    try {
      final results = await AifaCacheService.instance.search(rawCode);

      if (!mounted) return;
      setState(() => _isSearching = false);

      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.barcodeNotFound)),
        );
        // Resume scanning
        setState(() => _isPaused = false);
        return;
      }

      if (results.length == 1) {
        await _selectResult(results.first, rawCode);
      } else {
        await _showResultPicker(results, rawCode);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _isPaused = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.barcodeNotFound)),
        );
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
                color: Colors.grey[400],
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
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${results.length} ${l10n.results}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 13),
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
                      backgroundColor:
                          AppTheme.primaryColor.withValues(alpha: 0.15),
                      child: const Icon(Icons.medication,
                          color: AppTheme.primaryColor, size: 20),
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
                        Text(r.description,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        if (r.activeIngredient != null)
                          Text(r.activeIngredient!,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600])),
                        if (r.manufacturer != null)
                          Text(r.manufacturer!,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500])),
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
    } else if (mounted) {
      // User dismissed — resume scanning
      setState(() => _isPaused = false);
    }
  }

  Future<void> _selectResult(AifaSearchResult result, String code) async {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.autoFilledFromBarcode)),
    );
    context.pop();
    context.push(
      '${AppRoutes.addMedication}?barcode=$code',
      extra: result,
    );
  }

  void _showManualEntryDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();

    showDialog(
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
                _handleCode(codes.isNotEmpty ? codes.first : value);
              }
            },
            child: Text(l10n.useBarcode),
          ),
        ],
      ),
    );
  }
}

