/// Medora - Opening a backup file with the system picker.
///
/// Kept out of the widgets so tests (and any future non-Flutter caller) can
/// inject their own file instead of driving a native dialog.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Asks the user for a `.json` backup; null when they cancel.
Future<File?> pickBackupFile() async {
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (picked == null) return null;

  final path = picked.path;
  if (path != null) return File(path);

  // Some Android providers hand back a content URI with no path on disk;
  // copy the bytes into the cache so the service sees a real file.
  final cache = await getTemporaryDirectory();
  final copy = File(p.join(cache.path, p.basename(picked.name)));
  await copy.writeAsBytes(await picked.readAsBytes(), flush: true);
  return copy;
}
