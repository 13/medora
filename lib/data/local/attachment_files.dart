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

  /// Write [bytes] into the attachments folder under [fileName] (basename
  /// only).
  Future<File> write(String fileName, List<int> bytes) async {
    final dir = await _attachmentsDir();
    final file = File(p.join(dir.path, p.basename(fileName)));
    return file.writeAsBytes(bytes, flush: true);
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
