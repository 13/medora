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

  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};

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
    if (!_imageExtensions.contains(ext) && !_hasImageDecoder(raw)) {
      return const ImportRefused(ImportRefusal.unsupported);
    }
    final decoded = _decodeImage(raw);
    if (decoded == null) return const ImportRefused(ImportRefusal.unreadable);
    var image = img.bakeOrientation(decoded);
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge > maxLongEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxLongEdge)
          : img.copyResize(image, height: maxLongEdge);
    }
    image.exif = img.ExifData();
    final bytes = Uint8List.fromList(
      img.encodeJpg(image, quality: jpegQuality),
    );
    return Imported(
      kind: AttachmentKind.photo,
      mime: 'image/jpeg',
      bytes: bytes,
      sha256: sha256.convert(bytes).toString(),
      originalName: name,
    );
  }

  /// `image`'s decoder probing can throw on very short/malformed input
  /// (e.g. the PSD sniffer reads past the buffer) instead of returning
  /// null; that isn't a crash, it's just "no decoder recognizes this".
  static bool _hasImageDecoder(Uint8List raw) {
    try {
      return img.findDecoderForData(raw) != null;
    } catch (_) {
      return false;
    }
  }

  /// [img.decodeImage] shares the same decoder-probing quirk as
  /// [_hasImageDecoder]; a garbled-but-plausible file (e.g. a truncated
  /// JPEG with a `.jpg` name) should read as unreadable, not crash.
  static img.Image? _decodeImage(Uint8List raw) {
    try {
      return img.decodeImage(raw);
    } catch (_) {
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
