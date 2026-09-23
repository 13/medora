/// Medora - The server side of attachments: the metadata rows and the
/// private storage bucket holding the bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that creates `attachments` and the `attachments` bucket.
const attachmentsMigration =
    'supabase/migrations/20260924000000_attachments.sql';

/// The object is not in storage (or not visible to this user).
class AttachmentNotFound implements Exception {
  const AttachmentNotFound(this.path);
  final String path;

  @override
  String toString() => 'Attachment not in storage';
}

/// Storage has no `attachments` bucket: the project lacks
/// [attachmentsMigration]. storage-api answers `{"statusCode": "404",
/// "error": "Bucket not found", ...}`; for a JSON request `storage_client`
/// puts that `error` into [StorageException.error], for a download the raw
/// body is the message.
bool isMissingBucket(StorageException e) {
  if (e.error == 'Bucket not found') return true;
  Object? body;
  try {
    body = jsonDecode(e.message);
  } on FormatException {
    return false;
  }
  return body is Map && body['error'] == 'Bucket not found';
}

/// The bytes of attachments, one object per attachment under
/// `<auth.uid>/<attachment id>.<ext>`.
abstract interface class AttachmentStore {
  /// Uploads [bytes] to [path]; an object already there with the same
  /// path counts as done (the write was retried).
  Future<void> upload(String path, Uint8List bytes, {required String mime});

  /// Throws [AttachmentNotFound] when there is no such object.
  Future<Uint8List> download(String path);

  /// Missing objects are fine.
  Future<void> remove(List<String> paths);

  /// The object paths directly inside [folder].
  Future<List<String>> listFolder(String folder);
}

/// [AttachmentStore] on Supabase Storage.
///
/// Supabase's storage server (storage-api v1) answers most errors with HTTP
/// 400 and the real status in the JSON body: `{"statusCode": "409",
/// "error": "Duplicate", ...}` for an object already there,
/// `{"statusCode": "404", "error": "not_found", ...}` for a missing one.
/// `storage_client` puts that body status into [StorageException.statusCode]
/// for JSON requests, but a download keeps the raw body as the message and
/// the HTTP status as the code, so [download] reads the body itself.
class SupabaseAttachmentStore implements AttachmentStore {
  SupabaseAttachmentStore(this._client);

  static const bucket = 'attachments';

  /// Objects per list request.
  static const _pageSize = 100;

  final SupabaseClient _client;

  StorageFileApi get _files => _client.storage.from(bucket);

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required String mime,
  }) async {
    try {
      await _files.uploadBinary(
        path,
        bytes,
        // Never overwrite: contents are immutable.
        // ignore: avoid_redundant_argument_values
        fileOptions: FileOptions(contentType: mime, upsert: false),
      );
    } on StorageException catch (e) {
      // Already there: an earlier attempt landed but its answer was lost.
      if (e.statusCode == '409' || e.error == 'Duplicate') return;
      rethrow;
    }
  }

  @override
  Future<Uint8List> download(String path) async {
    try {
      return await _files.download(path);
    } on StorageException catch (e) {
      if (_isMissingObject(e)) throw AttachmentNotFound(path);
      rethrow;
    }
  }

  /// A missing object: a bare 404, or a 400 whose body says `not_found`.
  /// Not a missing bucket (the migration not applied), whose body also says
  /// 404: nothing is known about the object then.
  static bool _isMissingObject(StorageException e) {
    Object? body;
    try {
      body = jsonDecode(e.message);
    } on FormatException {
      body = null;
    }
    if (body is Map) {
      return body['statusCode']?.toString() == '404' &&
          body['error'] == 'not_found';
    }
    return e.statusCode == '404';
  }

  @override
  Future<void> remove(List<String> paths) async {
    if (paths.isEmpty) return;
    await _files.remove(paths);
  }

  @override
  Future<List<String>> listFolder(String folder) async {
    final paths = <String>[];
    for (var offset = 0; ; offset += _pageSize) {
      final page = await _files.list(
        path: folder,
        // The page size is ours, whatever the client's default.
        // ignore: avoid_redundant_argument_values
        searchOptions: SearchOptions(limit: _pageSize, offset: offset),
      );
      for (final o in page) {
        // An entry without an id is a sub-folder.
        if (o.id != null) paths.add('$folder/${o.name}');
      }
      if (page.length < _pageSize) return paths;
    }
  }
}

class AttachmentRemoteDatasource {
  AttachmentRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        'attachments',
        migration: attachmentsMigration,
        tableMigration: attachmentsMigration,
      ),
      store = SupabaseAttachmentStore(client);

  final SyncTable rows;
  final AttachmentStore store;
}
