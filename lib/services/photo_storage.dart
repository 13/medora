/// Medora - Medication photo storage.
///
/// Photos are stored under `<app documents>/medication_photos/<filename>` and
/// the database keeps only the filename, so the app container can move
/// (iOS does this on every update) without breaking references.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class PhotoStorage {
  PhotoStorage({required Future<Directory> Function() rootDirectory})
      : _rootDirectory = rootDirectory;

  /// Production storage rooted at the app documents directory.
  factory PhotoStorage.appDocuments() =>
      PhotoStorage(rootDirectory: getApplicationDocumentsDirectory);

  static const folder = 'medication_photos';
  static const _uuid = Uuid();

  final Future<Directory> Function() _rootDirectory;

  Future<Directory> _photosDir() async {
    final dir = Directory(p.join((await _rootDirectory()).path, folder));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The bare filename to persist for any stored value (absolute or bare).
  static String toStoredName(String pathOrName) => p.basename(pathOrName);

  /// Copy [sourcePath] into the photos folder; returns the bare filename.
  Future<String> saveFromPath(String sourcePath) async {
    final dir = await _photosDir();
    final name = 'med_${_uuid.v4()}${p.extension(sourcePath)}';
    await File(sourcePath).copy(p.join(dir.path, name));
    return name;
  }

  /// Resolve a stored value to an existing file.
  /// Accepts a bare filename (current format) or a legacy absolute path:
  /// if the absolute path still exists it is used, otherwise its basename is
  /// looked up in the current photos folder.
  Future<File?> resolve(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    if (p.isAbsolute(stored)) {
      final legacy = File(stored);
      if (legacy.existsSync()) return legacy;
    }
    final file = File(p.join((await _photosDir()).path, toStoredName(stored)));
    return file.existsSync() ? file : null;
  }

  Future<void> delete(String? stored) async {
    final file = await resolve(stored);
    if (file != null && file.existsSync()) await file.delete();
  }

  Future<void> deleteAll() async {
    final dir = await _photosDir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
