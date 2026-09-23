/// Medora - What preparing a picked photo or PDF for attaching produces.
///
/// Split out from `lib/services/attachment_import.dart` (which still does
/// the actual decoding/resizing and re-exports these) so the attachment
/// repository can accept an [Imported] without the data layer depending on
/// `lib/services`.
library;

import 'dart:typed_data';

import 'package:medora/domain/entities/attachment.dart';

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
