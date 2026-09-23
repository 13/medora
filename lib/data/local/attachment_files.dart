/// Medora - Attachment file storage.
///
/// Attachments are stored under `<app documents>/attachments/<id>.<ext>`;
/// the database keeps only the metadata row, so the app container can move
/// (iOS does this on every update) without breaking references.
library;

import 'dart:io';

import 'package:medora/domain/entities/attachment.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AttachmentFiles {
  AttachmentFiles({required this._rootDirectory});

  /// Production storage rooted at the app documents directory.
  factory AttachmentFiles.appDocuments() =>
      AttachmentFiles(rootDirectory: getApplicationDocumentsDirectory);

  static const folder = 'attachments';

  final Future<Directory> Function() _rootDirectory;

  Future<Directory> _attachmentsDir() async {
    final dir = Directory(p.join((await _rootDirectory()).path, folder));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The file for [a]; it may not exist yet.
  Future<File> fileFor(Attachment a) async =>
      File(p.join((await _attachmentsDir()).path, p.basename(a.fileName)));

  Future<bool> has(Attachment a) async => (await fileFor(a)).existsSync();

  /// Suffix of a file still being written.
  static const partSuffix = '.part';

  /// Write [bytes] into the attachments folder under [fileName] (basename
  /// only). The bytes go to `<fileName>.part` first and are renamed into
  /// place, so the file appears only complete: a kill half-way leaves a
  /// `.part` file, which the orphan sweep removes, never a truncated one.
  Future<File> write(String fileName, List<int> bytes) async {
    final dir = await _attachmentsDir();
    final target = p.join(dir.path, p.basename(fileName));
    final part = File('$target$partSuffix');
    try {
      await part.writeAsBytes(bytes, flush: true);
      return await part.rename(target);
    } catch (_) {
      try {
        if (part.existsSync()) await part.delete();
      } catch (_) {
        // Best effort: the orphan sweep removes it later.
      }
      rethrow;
    }
  }

  Future<void> delete(String fileName) async {
    final file = File(
      p.join((await _attachmentsDir()).path, p.basename(fileName)),
    );
    if (file.existsSync()) await file.delete();
  }

  /// When [fileName] was last written; null when there is no such file.
  Future<DateTime?> modifiedAt(String fileName) async {
    final file = File(
      p.join((await _attachmentsDir()).path, p.basename(fileName)),
    );
    return file.existsSync() ? file.lastModifiedSync() : null;
  }

  /// Every stored file's bare name, sorted.
  Future<List<String>> listNames() async {
    final dir = await _attachmentsDir();
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList();
    names.sort();
    return names;
  }

  Future<void> deleteAll() async {
    final dir = await _attachmentsDir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
