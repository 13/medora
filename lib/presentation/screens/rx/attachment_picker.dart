/// Medora - Picking a photo or file for a prescription, shared by the
/// attachments section and the scan sheet.
///
/// A camera/gallery pick is downscaled natively (`ImagePicker`'s
/// `maxWidth`/`maxHeight`/`imageQuality`) mostly to keep the raw bytes
/// manageable on a high-megapixel camera; [AttachmentImport] still strips
/// EXIF and re-encodes every photo regardless of where it came from, so
/// this is a size optimisation, not the place import rules live.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// What the section needs from the platform to obtain a picked file's path
/// (and, for the file picker, its original name) — kept as a port so
/// widget tests can supply a fake instead of driving platform channels.
abstract interface class AttachmentPicker {
  Future<({String path, String? name})?> camera();
  Future<({String path, String? name})?> gallery();
  Future<({String path, String? name})?> file(); // pdf, jpg, jpeg, png
}

class PlatformAttachmentPicker implements AttachmentPicker {
  const PlatformAttachmentPicker();

  /// The device's own camera/gallery downscale (see the library doc); the
  /// import pipeline resizes and re-encodes regardless.
  static const _maxDimension = 2400.0;
  static const _imageQuality = 95;

  @override
  Future<({String path, String? name})?> camera() =>
      _fromImagePicker(ImageSource.camera);

  @override
  Future<({String path, String? name})?> gallery() =>
      _fromImagePicker(ImageSource.gallery);

  Future<({String path, String? name})?> _fromImagePicker(
    ImageSource source,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: _maxDimension,
      maxHeight: _maxDimension,
      imageQuality: _imageQuality,
    );
    if (picked == null) return null;
    return (path: picked.path, name: picked.name);
  }

  @override
  Future<({String path, String? name})?> file() async {
    final picked = await fp.FilePicker.pickFile(
      type: fp.FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (picked == null) return null;
    final existingPath = picked.path;
    if (existingPath != null) return (path: existingPath, name: picked.name);

    // Some Android providers hand back a content URI with no path on disk;
    // copy the bytes into the cache so the import sees a real file (as
    // `pickBackupFile` does for the backup restore flow).
    final cache = await getTemporaryDirectory();
    final copy = File(path.join(cache.path, path.basename(picked.name)));
    await copy.writeAsBytes(await picked.readAsBytes(), flush: true);
    return (path: copy.path, name: picked.name);
  }
}

final attachmentPickerProvider = Provider<AttachmentPicker>(
  (_) => const PlatformAttachmentPicker(),
);

/// Preparing a picked file, as a provider — so widget tests can swap in a
/// synchronous stand-in. [AttachmentImport.fromPath] runs the real decode
/// on a background isolate via `compute`, which never returns under
/// `testWidgets`'s fake-async test binding.
typedef AttachmentImporter =
    Future<ImportResult> Function(String path, {String? originalName});

final attachmentImportProvider = Provider<AttachmentImporter>(
  (_) => AttachmentImport.fromPath,
);

/// Deletes [filePath] when it lives inside the app's temp/cache directory
/// — our own content-URI copy from [PlatformAttachmentPicker.file], or a
/// cache copy the platform picker itself returned — never a path outside
/// it (e.g. a real file from the user's own storage). [viaFilePicker] also
/// asks the `file_picker` plugin to drop its own temporary files, once
/// this device's installed version supports it.
Future<void> cleanUpPickedFile(
  String filePath, {
  required AttachmentPicker picker,
  required bool viaFilePicker,
}) async {
  try {
    final tempDir = await getTemporaryDirectory();
    if (path.isWithin(tempDir.path, filePath)) {
      final file = File(filePath);
      if (file.existsSync()) await file.delete();
    }
  } catch (_) {
    // Best-effort: worst case a leftover temp file, never surfaced.
  }
  if (viaFilePicker && picker is PlatformAttachmentPicker) {
    try {
      await fp.FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Not supported on every platform; harmless either way.
    }
  }
}
