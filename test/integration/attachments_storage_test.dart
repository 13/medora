/// Attachments against a local Supabase (`supabase start`) with every
/// migration applied: the private `attachments` bucket, its folder
/// policies and limits, and "delete all data" emptying the caller's folder,
/// through the real storage API and [SupabaseAttachmentStore].
///
/// Run (see `local_supabase.dart`):
///   fvm flutter test test/integration/attachments_storage_test.dart \
///     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///     --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/account_data_remote_datasource.dart';
import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'local_supabase.dart';

const _uuid = Uuid();

/// A few bytes that start like a JPEG; the bucket checks the declared MIME
/// type and the size, not the contents.
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

/// A signed-in account with its own [SupabaseAttachmentStore].
class _Account {
  _Account(this.client, this.userId)
    : remote = AttachmentRemoteDatasource(client);

  final SupabaseClient client;
  final String userId;
  final AttachmentRemoteDatasource remote;

  AttachmentStore get store => remote.store;

  static Future<_Account> create() async {
    final account = await signUp();
    return _Account(account.client, account.userId);
  }

  /// Uploads a photo into this account's folder and returns its path.
  Future<String> uploadPhoto() async {
    final path = '$userId/${_uuid.v4()}.jpg';
    await store.upload(path, _jpeg, mime: 'image/jpeg');
    return path;
  }
}

void main() {
  final skip = localSupabaseConfigured ? false : localSupabaseSkip;

  test('the owner uploads <uid>/<id>.jpg and reads it back; the same upload '
      'again counts as done', () async {
    final a = await _Account.create();
    final path = await a.uploadPhoto();

    expect(await a.store.download(path), _jpeg);
    expect(await a.store.listFolder(a.userId), [path]);
    await a.store.upload(path, _jpeg, mime: 'image/jpeg');
    expect(await a.store.listFolder(a.userId), [path]);
  }, skip: skip);

  test('another account cannot download, list, remove or upload into the '
      "owner's folder", () async {
    final a = await _Account.create();
    final b = await _Account.create();
    final path = await a.uploadPhoto();

    await expectLater(
      b.store.download(path),
      throwsA(isA<AttachmentNotFound>()),
    );
    expect(await b.store.listFolder(a.userId), isEmpty);
    // The storage API answers a remove it may not do as one of nothing.
    await b.store.remove([path]);
    expect(await a.store.download(path), _jpeg);
    await expectLater(
      b.store.upload(
        '${a.userId}/${_uuid.v4()}.jpg',
        _jpeg,
        mime: 'image/jpeg',
      ),
      throwsA(
        isA<StorageException>().having((e) => e.statusCode, 'status', '403'),
      ),
    );
    expect(await a.store.listFolder(a.userId), [path]);
  }, skip: skip);

  test('the bucket refuses a PDF over 20 MB and a text file', () async {
    final a = await _Account.create();
    final big = Uint8List(20 * 1024 * 1024 + 1);
    await expectLater(
      a.store.upload(
        '${a.userId}/${_uuid.v4()}.pdf',
        big,
        mime: 'application/pdf',
      ),
      throwsA(
        isA<StorageException>().having((e) => e.statusCode, 'status', '413'),
      ),
    );
    await expectLater(
      a.store.upload(
        '${a.userId}/${_uuid.v4()}.txt',
        Uint8List.fromList('hello'.codeUnits),
        mime: 'text/plain',
      ),
      throwsA(
        isA<StorageException>().having((e) => e.statusCode, 'status', '415'),
      ),
    );
    expect(await a.store.listFolder(a.userId), isEmpty);
  }, skip: skip);

  test('"delete all data" leaves the caller\'s folder empty and another '
      'account\'s alone', () async {
    final a = await _Account.create();
    final bystander = await _Account.create();
    final id = _uuid.v4();
    final path = '${a.userId}/$id.jpg';
    await a.store.upload(path, _jpeg, mime: 'image/jpeg');
    await a.uploadPhoto();
    await a.remote.rows.insertIfAbsent([
      {
        'id': id,
        'user_id': a.userId,
        'owner_kind': 'rx',
        'owner_id': _uuid.v4(),
        'kind': 'photo',
        'mime': 'image/jpeg',
        'size_bytes': _jpeg.length,
        'sha256': 'abc',
        'remote_path': path,
        'write_id': _uuid.v4(),
        'edited_at': DateTime.now().toUtc().toIso8601String(),
        'field_edited_at': <String, Object?>{},
      },
    ]);
    final kept = await bystander.uploadPhoto();
    expect(await a.store.listFolder(a.userId), hasLength(2));

    await AccountDataRemoteDatasource(
      a.client,
      attachments: a.store,
    ).deleteAllData();

    expect(await a.store.listFolder(a.userId), isEmpty);
    expect(await a.remote.rows.fetchMany([id]), isEmpty);
    expect(await bystander.store.listFolder(bystander.userId), [kept]);
  }, skip: skip);
}
