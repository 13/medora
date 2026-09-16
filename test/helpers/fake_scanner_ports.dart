import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/scanner_ports.dart';

/// Text recognition that answers from a script instead of ML Kit.
class FakeTextRecognition implements TextRecognitionPort {
  FakeTextRecognition(this.linesByPass) : assert(linesByPass.isNotEmpty);

  /// Lines returned per call, in order; a null entry throws (the recogniser
  /// failing), and the last entry answers every further call.
  final List<List<OcrLine>?> linesByPass;

  /// Every image handed in, in order.
  final calls = <ScanImage>[];
  int closeCalls = 0;
  var _index = 0;

  @override
  Future<List<OcrLine>> linesIn(ScanImage image) async {
    calls.add(image);
    final lines = linesByPass[_index.clamp(0, linesByPass.length - 1)];
    _index++;
    if (lines == null) throw StateError('text recognition failed');
    return lines;
  }

  @override
  Future<void> close() async => closeCalls++;
}

/// Barcode scanning that answers from a script instead of ML Kit.
class FakeBarcodeScan implements BarcodeScanPort {
  FakeBarcodeScan(this.candidatesByPass) : assert(candidatesByPass.isNotEmpty);

  /// Candidates returned per call, in order; a null entry throws, and the
  /// last entry answers every further call.
  final List<List<CodeCandidate>?> candidatesByPass;

  final calls = <ScanImage>[];
  int closeCalls = 0;
  var _index = 0;

  @override
  Future<List<CodeCandidate>> candidatesIn(ScanImage image) async {
    calls.add(image);
    final found =
        candidatesByPass[_index.clamp(0, candidatesByPass.length - 1)];
    _index++;
    if (found == null) throw StateError('barcode scanning failed');
    return found;
  }

  @override
  Future<void> close() async => closeCalls++;
}

/// A camera that hands out a photo the test wrote.
class FakeCamera implements CameraPort {
  FakeCamera({this.photoPath, this.opens = true, this.failsToOpen = false});

  /// What [takePicture] returns; null pretends no photo was written.
  String? photoPath;

  /// Whether the device has a camera at all.
  bool opens;

  /// Whether opening it throws.
  bool failsToOpen;

  /// Whether the torch obeys [setTorch].
  bool torchWorks = true;

  bool torchOn = false;
  int initializeCalls = 0;
  int disposeCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int takePictureCalls = 0;
  final focusPoints = <Offset>[];

  bool _ready = false;
  bool _taking = false;

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    if (failsToOpen) throw StateError('camera unavailable');
    _ready = opens;
    return opens;
  }

  @override
  bool get isReady => _ready;

  @override
  bool get isTakingPicture => _taking;

  @override
  Size? get previewSize => _ready ? const Size(1920, 1080) : null;

  @override
  Widget buildPreview(BuildContext context) => const ColoredBox(
    key: ValueKey('fakeCameraPreview'),
    color: Color(0xFF123456),
    child: SizedBox.expand(),
  );

  @override
  Future<String?> takePicture() async {
    takePictureCalls++;
    _taking = true;
    await Future<void>.value();
    _taking = false;
    return photoPath;
  }

  @override
  Future<bool> setTorch(bool on) async {
    if (!torchWorks) return false;
    torchOn = on;
    return true;
  }

  @override
  Future<void> setFocusPoint(Offset normalized) async =>
      focusPoints.add(normalized);

  @override
  Future<void> pausePreview() async => pauseCalls++;

  @override
  Future<void> resumePreview() async => resumeCalls++;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _ready = false;
  }
}

/// A gallery picker that returns a fixed path, or null for a cancel.
class FakeGallery implements GalleryPort {
  FakeGallery({this.path, this.fails = false});

  String? path;

  /// Whether picking throws (the picker refused, e.g. no permission).
  bool fails;
  int calls = 0;

  @override
  Future<String?> pickImage() async {
    calls++;
    if (fails) throw StateError('gallery unavailable');
    return path;
  }
}

/// Overrides for the four scanner ports; anything left out gets a fake that
/// finds nothing, so no test can reach a real plugin by forgetting one.
List<Override> scannerOverrides({
  TextRecognitionPort? text,
  BarcodeScanPort? barcodes,
  CameraPort? camera,
  GalleryPort? gallery,
}) => [
  textRecognitionPortProvider.overrideWithValue(
    text ?? FakeTextRecognition(const [<OcrLine>[]]),
  ),
  barcodeScanPortProvider.overrideWithValue(
    barcodes ?? FakeBarcodeScan(const [<CodeCandidate>[]]),
  ),
  cameraPortProvider.overrideWithValue(camera ?? FakeCamera()),
  galleryPortProvider.overrideWithValue(gallery ?? FakeGallery()),
];
