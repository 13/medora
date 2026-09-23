/// Medora - Turning a picked photo or PDF into what is stored.
///
/// Photos: decoded, orientation baked into the pixels, scaled to at most
/// [AttachmentImport.maxLongEdge] px, re-encoded as JPEG
/// [AttachmentImport.jpegQuality] with no metadata — a phone photo carries
/// GPS and device data that has no business next to a prescription. PDFs:
/// kept as they are, up to [AttachmentImport.maxPdfBytes]. Anything else is
/// refused. Runs in an isolate: a 12 MP decode takes seconds.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:medora/domain/entities/attachment.dart';
import 'package:path/path.dart' as p;

sealed class ImportResult {
  const ImportResult();
}

final class Imported extends ImportResult {
  const Imported({
    required this.kind,
    required this.mime,
    required this.bytes,
    required this.sha256,
    this.originalName,
  });
  final AttachmentKind kind;
  final String mime;
  final Uint8List bytes;
  final String sha256;
  final String? originalName;
}

enum ImportRefusal { tooLarge, unsupported, unreadable }

final class ImportRefused extends ImportResult {
  const ImportRefused(this.reason);
  final ImportRefusal reason;
}

abstract final class AttachmentImport {
  static const maxLongEdge = 2400;
  static const jpegQuality = 85;
  static const maxPdfBytes = 20 * 1024 * 1024;

  /// A decoded image above this many pixels needs ~4 bytes/px of RGBA plus
  /// resize/encode buffers — an 8000x6000 photo alone is ~192 MB — enough to
  /// OOM a phone isolate. Checked against header-only dimensions, before any
  /// pixel data is decoded.
  static const maxImagePixels = 60 * 1000 * 1000;

  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};

  /// Exposed so tests can simulate an encode failure after a successful
  /// decode; production code always uses [img.encodeJpg] itself.
  @visibleForTesting
  static Uint8List Function(img.Image image, {int quality}) jpegEncoder =
      img.encodeJpg;

  /// Reads [path] and prepares it off the main isolate; a 12 MP decode takes
  /// seconds and would otherwise jank the UI.
  static Future<ImportResult> fromPath(
    String path, {
    String? originalName,
  }) async {
    final raw = await File(path).readAsBytes();
    final name = originalName ?? p.basename(path);
    return compute(_prepareArgs, (raw, name));
  }

  static ImportResult _prepareArgs((Uint8List, String) args) =>
      prepare(args.$1, nameOrPath: args.$2);

  /// Pure: no I/O, safe to call directly in tests or inside [compute].
  static ImportResult prepare(Uint8List raw, {required String nameOrPath}) {
    final name = p.basename(nameOrPath);
    final ext = p.extension(name).toLowerCase();
    if (_isPdf(raw)) {
      if (raw.length > maxPdfBytes) {
        return const ImportRefused(ImportRefusal.tooLarge);
      }
      return Imported(
        kind: AttachmentKind.pdf,
        mime: 'application/pdf',
        bytes: raw,
        sha256: sha256.convert(raw).toString(),
        originalName: name,
      );
    }
    // A large image would otherwise decode to hundreds of MB of pixels
    // before we get a chance to resize it down. Refuse by raw byte size
    // first (cheapest possible check), then by header-only dimensions —
    // neither touches a single pixel.
    if (raw.length > maxPdfBytes) {
      return const ImportRefused(ImportRefusal.tooLarge);
    }
    if (!_imageExtensions.contains(ext) && !_hasImageDecoder(raw)) {
      return const ImportRefused(ImportRefusal.unsupported);
    }
    if (_imageDimensionsExceedLimit(raw)) {
      return const ImportRefused(ImportRefusal.tooLarge);
    }
    final decoded = _decodeImage(raw);
    if (decoded == null) return const ImportRefused(ImportRefusal.unreadable);
    return _finishPhoto(decoded, name);
  }

  /// Bakes orientation, resizes and re-encodes an already-decoded image.
  /// These calls operate on a successfully decoded pixel buffer so they
  /// should never fail, but "should never" isn't a guarantee (see the
  /// image-package quirk documented on [_hasImageDecoder]) — every import
  /// failure must be a result, never an exception out of [prepare].
  static ImportResult _finishPhoto(img.Image decoded, String name) {
    try {
      var image = img.bakeOrientation(decoded);
      final longEdge = image.width > image.height ? image.width : image.height;
      if (longEdge > maxLongEdge) {
        image = image.width >= image.height
            ? img.copyResize(image, width: maxLongEdge)
            : img.copyResize(image, height: maxLongEdge);
      }
      image.exif = img.ExifData();
      final bytes = Uint8List.fromList(
        jpegEncoder(image, quality: jpegQuality),
      );
      return Imported(
        kind: AttachmentKind.photo,
        mime: 'image/jpeg',
        bytes: bytes,
        sha256: sha256.convert(bytes).toString(),
        originalName: name,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return const ImportRefused(ImportRefusal.unreadable);
    }
  }

  /// True when the image's header-only dimensions (no pixel data decoded)
  /// exceed [maxImagePixels]. False when the header can't be read at all —
  /// that input still goes on to the real decode, which already refuses
  /// malformed data as [ImportRefusal.unreadable].
  static bool _imageDimensionsExceedLimit(Uint8List raw) {
    try {
      final info = img.findDecoderForData(raw)?.startDecode(raw);
      if (info == null) return false;
      return exceedsMaxPixels(info.width, info.height);
    } on RangeError catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return false;
    } on img.ImageException catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return false;
    }
  }

  /// Pure width/height check against [maxImagePixels], split out so it's
  /// testable without constructing real image bytes.
  @visibleForTesting
  static bool exceedsMaxPixels(int width, int height) =>
      width * height > maxImagePixels;

  /// `image`'s decoder probing can throw on very short/malformed input
  /// (e.g. the PSD sniffer reads past the buffer) instead of returning
  /// null; that isn't a crash, it's just "no decoder recognizes this".
  static bool _hasImageDecoder(Uint8List raw) {
    try {
      return img.findDecoderForData(raw) != null;
    } on RangeError catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return false;
    } on img.ImageException catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return false;
    }
  }

  /// [img.decodeImage] shares the same decoder-probing quirk as
  /// [_hasImageDecoder]; a garbled-but-plausible file (e.g. a truncated
  /// JPEG with a `.jpg` name) should read as unreadable, not crash.
  static img.Image? _decodeImage(Uint8List raw) {
    try {
      return img.decodeImage(raw);
    } on RangeError catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return null;
    } on img.ImageException catch (e) {
      if (kDebugMode) debugPrint('AttachmentImport: ${e.runtimeType}');
      return null;
    }
  }

  static bool _isPdf(Uint8List raw) =>
      raw.length >= 5 &&
      raw[0] == 0x25 &&
      raw[1] == 0x50 &&
      raw[2] == 0x44 &&
      raw[3] == 0x46 &&
      raw[4] == 0x2D; // %PDF-
}
