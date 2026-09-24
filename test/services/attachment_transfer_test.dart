import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/repositories/attachment_repository_impl.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/attachment_import_result.dart';
import 'package:medora/services/attachment_transfer.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

const _uid = 'user-a';

/// The SHA-256 of the bytes [7, 8] the download tests store.
final _sha78 = sha256.convert([7, 8]).toString();

/// A store whose uploads can be held open, or run a hook once stored.
class _GatedStore extends FakeAttachmentStore {
  _GatedStore() : super(currentUserId: _uid);

  Completer<void>? gate;
  Future<void> Function()? afterUpload;
  Completer<void>? downloadGate;
  int downloadsStarted = 0;

  @override
  Future<Uint8List> download(String path) async {
    downloadsStarted++;
    final g = downloadGate;
    if (g != null) await g.future;
    return super.download(path);
  }

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required String mime,
  }) async {
    await super.upload(path, bytes, mime: mime);
    final g = gate;
    if (g != null) await g.future;
    final hook = afterUpload;
    if (hook != null) await hook();
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  late DateTime now;
  late Directory root;
  late AttachmentFiles files;
  late AttachmentLocalDatasource local;
  late AttachmentRepositoryImpl repo;
  late _GatedStore store;
  String? uid;
  var online = true;

  setUp(() async {
    now = DateTime(2026, 9, 24, 9);
    uid = _uid;
    online = true;
    root = await Directory.systemTemp.createTemp('att-transfer');
    files = AttachmentFiles(rootDirectory: () async => root);
    local = AttachmentLocalDatasource(now: () => now);
    repo = AttachmentRepositoryImpl(local: local, files: files, now: () => now);
    store = _GatedStore();
  });
  tearDown(() => root.delete(recursive: true));

  AttachmentTransfer transfer({bool withStore = true}) => AttachmentTransfer(
    local: local,
    repository: repo,
    files: files,
    store: withStore ? store : null,
    currentUserId: () => uid,
    isOnline: () => online,
    now: () => now,
  );

  Future<Attachment> add({List<int> bytes = const [1, 2, 3]}) async =>
      (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        Imported(
          kind: AttachmentKind.photo,
          mime: 'image/jpeg',
          bytes: Uint8List.fromList(bytes),
          sha256: 'abc',
        ),
      )).dataOrNull!;

  Future<Map<String, Object?>> rowOf(String id) async =>
      (await (await AppDatabase.instance.database).query(
        'attachments',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('an attachment added here is uploaded to <uid>/<id>.jpg and its row '
      'records the path', () async {
    final a = await add();
    final report = await transfer().run();
    final path = '$_uid/${a.id}.jpg';
    expect(report.uploaded, 1);
    expect(report.failed, 0);
    expect(store.objects[path], [1, 2, 3]);
    expect(store.mimes[path], 'image/jpeg');
    final row = await rowOf(a.id);
    expect(row['remote_path'], path);
    expect(row['sync_status'], SyncStatus.pendingUpdate);
    // Nothing left to do on the next pass.
    final again = await transfer().run();
    expect(again.uploaded, 0);
    expect(store.uploads, 1);
  });

  for (final (name, setup) in <(String, void Function())>[
    ('no user signed in', () => uid = null),
    ('offline', () => online = false),
  ]) {
    test('$name: run does nothing', () async {
      final a = await add();
      await files.write('orphan.jpg', [9]);
      setup();
      final report = await transfer().run();
      expect(report.isEmpty, isTrue);
      expect(store.uploads + store.removes + store.lists, 0);
      expect((await rowOf(a.id))['remote_path'], isNull);
      expect(await files.listNames(), contains('orphan.jpg'));
    });
  }

  test('local-only (no store): run does nothing', () async {
    final a = await add();
    final report = await transfer(withStore: false).run();
    expect(report.isEmpty, isTrue);
    expect((await rowOf(a.id))['remote_path'], isNull);
  });

  test('a failed upload backs off 1 min, then 5 min, then succeeds', () async {
    final a = await add();
    final t = transfer();

    store.failNext = 1;
    var report = await t.run();
    expect(report.failed, 1);
    expect(report.uploaded, 0);
    expect((await rowOf(a.id))['remote_path'], isNull);

    now = now.add(const Duration(seconds: 30));
    report = await t.run();
    expect(store.uploads, 1, reason: 'still backing off');
    expect(report.isEmpty, isTrue);

    now = now.add(const Duration(seconds: 31));
    store.failNext = 1;
    report = await t.run();
    expect(report.failed, 1);
    expect(store.uploads, 2);

    now = now.add(const Duration(minutes: 4));
    await t.run();
    expect(store.uploads, 2, reason: 'second back-off is 5 minutes');

    now = now.add(const Duration(minutes: 1, seconds: 1));
    report = await t.run();
    expect(report.uploaded, 1);
    expect((await rowOf(a.id))['remote_path'], '$_uid/${a.id}.jpg');
  });

  test('back-off caps at 2 hours', () {
    expect(AttachmentTransfer.backoffAfter(1), const Duration(minutes: 1));
    expect(AttachmentTransfer.backoffAfter(2), const Duration(minutes: 5));
    expect(AttachmentTransfer.backoffAfter(3), const Duration(minutes: 30));
    expect(AttachmentTransfer.backoffAfter(4), const Duration(hours: 2));
    expect(AttachmentTransfer.backoffAfter(40), const Duration(hours: 2));
  });

  test('a file not written yet is skipped, not failed', () async {
    final a = await add();
    await files.delete(a.fileName);
    final report = await transfer().run();
    expect(report.isEmpty, isTrue);
    expect(store.uploads, 0);
  });

  test('deleted while uploading: the object is removed on the next pass and '
      'the row stays deleted', () async {
    final a = await add();
    final path = '$_uid/${a.id}.jpg';
    store.afterUpload = () async {
      store.afterUpload = null;
      expect((await repo.delete(a.id)).isSuccess, isTrue);
    };
    final t = transfer();
    final report = await t.run();
    expect(report.uploaded, 0);
    expect(store.objects, contains(path));
    expect(await local.pendingRemovals(), [path]);
    final row = await rowOf(a.id);
    expect(row['deleted_at'], isNotNull);
    expect(row['remote_path'], isNull);

    final next = await t.run();
    expect(next.removed, 1);
    expect(store.objects, isEmpty);
    expect(await local.pendingRemovals(), isEmpty);
  });

  test('removals go through the store; a failure keeps them queued', () async {
    await local.enqueueRemoval('$_uid/x.jpg');
    store.objects['$_uid/x.jpg'] = Uint8List.fromList([1]);
    final t = transfer();

    store.failNext = 1;
    var report = await t.run();
    expect(report.failed, 1);
    expect(await local.pendingRemovals(), ['$_uid/x.jpg']);

    now = now.add(const Duration(minutes: 2));
    report = await t.run();
    expect(report.removed, 1);
    expect(store.objects, isEmpty);
    expect(await local.pendingRemovals(), isEmpty);
  });

  test('sweep deletes old files without a row and keeps every other', () async {
    final live = await add();
    final tombstoned = await add(bytes: [4]);
    // A tombstone whose file somehow survived (still pending its push).
    await local.markDeleted(tombstoned.id);
    await files.write(tombstoned.fileName, [4]);
    final orphan = await files.write('gone.jpg', [5]);
    final fresh = await files.write('being-added.pdf', [6]);
    final old = now.subtract(const Duration(hours: 1));
    for (final f in [
      await files.fileFor(live),
      await files.fileFor(tombstoned),
      orphan,
    ]) {
      f.setLastModifiedSync(old);
    }
    // Written a minute ago: its row may not be stored yet.
    fresh.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));

    final report = await transfer().run();
    expect(report.swept, 1);
    expect(
      await files.listNames(),
      ['being-added.pdf', live.fileName, tombstoned.fileName]..sort(),
    );
  });

  test('open downloads a synced attachment once, then reads it here', () async {
    final a = Attachment(
      id: 'a9',
      ownerKind: AttachmentOwnerKind.rx,
      ownerId: 'r1',
      kind: AttachmentKind.photo,
      mime: 'image/jpeg',
      sizeBytes: 2,
      sha256: _sha78,
      remotePath: '$_uid/a9.jpg',
    );
    store.objects['$_uid/a9.jpg'] = Uint8List.fromList([7, 8]);
    final t = transfer();
    final first = await t.open(a);
    expect(await first!.readAsBytes(), [7, 8]);
    final second = await t.open(a);
    expect(second!.path, first.path);
    expect(store.downloads, 1);
  });

  test('open of a missing object, or one not uploaded yet, is null', () async {
    const a = Attachment(
      id: 'a9',
      ownerKind: AttachmentOwnerKind.rx,
      ownerId: 'r1',
      kind: AttachmentKind.pdf,
      mime: 'application/pdf',
      sizeBytes: 2,
      sha256: 'x',
      remotePath: '$_uid/a9.pdf',
    );
    final t = transfer();
    expect(await t.open(a), isNull);
    expect(store.downloads, 1);
    const notUploaded = Attachment(
      id: 'a10',
      ownerKind: AttachmentOwnerKind.rx,
      ownerId: 'r1',
      kind: AttachmentKind.pdf,
      mime: 'application/pdf',
      sizeBytes: 2,
      sha256: 'x',
    );
    expect(await t.open(notUploaded), isNull);
    store.failNext = 1;
    expect(await t.open(a), isNull, reason: 'a network error is not thrown');
    expect(store.downloads, 2);
  });

  test('a run while one is in progress is folded into one more pass', () async {
    final a = await add();
    final t = transfer();
    store.gate = Completer<void>();
    final running = t.run();
    await Future<void>.delayed(Duration.zero);
    while (store.uploads == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // Queued while the first pass is still uploading.
    await local.enqueueRemoval('$_uid/old.jpg');
    final folded = await t.run();
    expect(folded.isEmpty, isTrue);
    store.gate!.complete();
    store.gate = null;
    final report = await running;
    expect(report.uploaded, 1);
    expect(report.removed, 1, reason: 'the second pass ran');
    expect((await rowOf(a.id))['remote_path'], '$_uid/${a.id}.jpg');
  });

  Attachment synced(String id, {int sizeBytes = 2}) => Attachment(
    id: id,
    ownerKind: AttachmentOwnerKind.rx,
    ownerId: 'r1',
    kind: AttachmentKind.photo,
    mime: 'image/jpeg',
    sizeBytes: sizeBytes,
    sha256: _sha78,
    remotePath: '$_uid/$id.jpg',
  );

  test('two opens of the same attachment download it once', () async {
    final a = synced('a9');
    store.objects['$_uid/a9.jpg'] = Uint8List.fromList([7, 8]);
    store.downloadGate = Completer<void>();
    final t = transfer();
    final first = t.open(a);
    final second = t.open(a);
    while (store.downloadsStarted == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // Give the second open every chance to start its own download.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.downloadsStarted, 1);
    store.downloadGate!.complete();
    final files = await Future.wait([first, second]);
    expect(store.downloads, 1);
    expect(await files[0]!.readAsBytes(), [7, 8]);
    expect(files[1]!.path, files[0]!.path);
    // A later open that has to download again is not stuck on the first.
    await files[0]!.delete();
    store.downloadGate = null;
    expect(await t.open(a), isNotNull);
    expect(store.downloads, 2);
  });

  test('a download of the wrong size is not written', () async {
    final a = synced('a9');
    store.objects['$_uid/a9.jpg'] = Uint8List.fromList([7, 8, 9]);
    expect(await transfer().open(a), isNull);
    expect(await files.listNames(), isEmpty);
  });

  test('a download of the right size but other contents is not '
      'written', () async {
    final a = synced('a9');
    store.objects['$_uid/a9.jpg'] = Uint8List.fromList([8, 7]);
    expect(await transfer().open(a), isNull);
    expect(await files.listNames(), isEmpty);
  });

  test('a file is written under a temporary name first: a failed write '
      'leaves nothing under its own name', () async {
    final dir = Directory(p.join(root.path, AttachmentFiles.folder));
    await dir.create(recursive: true);
    // The temporary file cannot be written: a directory is in its way.
    await Directory(p.join(dir.path, 'x.jpg.part')).create();
    await expectLater(files.write('x.jpg', [1, 2]), throwsA(anything));
    expect(File(p.join(dir.path, 'x.jpg')).existsSync(), isFalse);
    await Directory(p.join(dir.path, 'x.jpg.part')).delete();

    final file = await files.write('x.jpg', [1, 2]);
    expect(await file.readAsBytes(), [1, 2]);
    expect(await files.listNames(), ['x.jpg'], reason: 'no temporary left');
  });

  test(
    'sweep deletes a stale partial download and keeps a fresh one',
    () async {
      await add();
      final dir = Directory(p.join(root.path, AttachmentFiles.folder));
      final stale = File(p.join(dir.path, 'old.jpg.part'))
        ..writeAsBytesSync([1]);
      stale.setLastModifiedSync(now.subtract(const Duration(hours: 1)));
      final fresh = File(p.join(dir.path, 'new.jpg.part'))
        ..writeAsBytesSync([1]);
      fresh.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));
      final report = await transfer().run();
      expect(report.swept, 1);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    },
  );

  test("removals of another user's objects stay queued", () async {
    await local.enqueueRemoval('user-b/x.jpg');
    await local.enqueueRemoval('$_uid/y.jpg');
    store.objects['$_uid/y.jpg'] = Uint8List.fromList([1]);
    final report = await transfer().run();
    expect(report.removed, 1);
    expect(store.objects, isEmpty);
    expect(await local.pendingRemovals(), ['user-b/x.jpg']);
  });

  test('a row gone before its upload is recorded: the object is queued and '
      'not retried', () async {
    final a = await add();
    final path = '$_uid/${a.id}.jpg';
    store.afterUpload = () async {
      store.afterUpload = null;
      await (await AppDatabase.instance.database).delete('attachments');
    };
    final t = transfer();
    final report = await t.run();
    expect(report.uploaded, 0);
    expect(report.failed, 0);
    expect(await local.pendingRemovals(), [path]);
    final next = await t.run();
    expect(next.removed, 1);
    expect(store.objects, isEmpty);
  });

  test('after an account change the files are uploaded again into the new '
      "account's folder", () async {
    final a = await add();
    await transfer().run();
    expect((await rowOf(a.id))['remote_path'], '$_uid/${a.id}.jpg');
    await (await AppDatabase.instance.database).update('attachments', {
      'user_id': _uid,
      'sync_status': SyncStatus.synced,
    });
    SharedPreferences.setMockInitialValues({LocalUploadMarker.ownerKey: _uid});
    final marker = LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: SyncCursorStore.inMemory(),
      prefs: await SharedPreferences.getInstance(),
    );
    await marker.markAllForUpload('user-b');
    final row = await rowOf(a.id);
    expect(row['remote_path'], isNull);
    expect(row['user_id'], isNull);

    uid = 'user-b';
    store.currentUserId = 'user-b';
    final report = await transfer().run();
    expect(report.uploaded, 1);
    expect(store.objects, contains('user-b/${a.id}.jpg'));
    expect((await rowOf(a.id))['remote_path'], 'user-b/${a.id}.jpg');
  });

  for (final owner in [null, 'user-b']) {
    test("a restored backup of another account's rows is uploaded again "
        'into the signed-in folder (device owner $owner)', () async {
      final a = await add();
      // As a restore writes them: user A's owner and path, the file here.
      await (await AppDatabase.instance.database).update('attachments', {
        'user_id': _uid,
        'remote_path': '$_uid/${a.id}.jpg',
        'sync_status': SyncStatus.synced,
      });
      SharedPreferences.setMockInitialValues({
        LocalUploadMarker.ownerKey: ?owner,
      });
      final marker = LocalUploadMarker(
        database: AppDatabase.instance,
        cursors: SyncCursorStore.inMemory(),
        prefs: await SharedPreferences.getInstance(),
      );
      await marker.markAllForUpload('user-b');
      final row = await rowOf(a.id);
      expect(row['remote_path'], isNull);
      expect(row['user_id'], isNull);

      uid = 'user-b';
      store.currentUserId = 'user-b';
      final report = await transfer().run();
      expect(report.uploaded, 1);
      expect((await rowOf(a.id))['remote_path'], 'user-b/${a.id}.jpg');
    });
  }

  test("a row with no owner but another account's path is uploaded "
      'again', () async {
    final a = await add();
    await (await AppDatabase.instance.database).update('attachments', {
      'remote_path': '$_uid/${a.id}.jpg',
      'sync_status': SyncStatus.synced,
    });
    SharedPreferences.setMockInitialValues({});
    final marker = LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: SyncCursorStore.inMemory(),
      prefs: await SharedPreferences.getInstance(),
    );
    await marker.markAllForUpload('user-b');
    expect((await rowOf(a.id))['remote_path'], isNull);
  });

  test("a signed-in user's own uploaded rows keep their path", () async {
    final a = await add();
    await (await AppDatabase.instance.database).update('attachments', {
      'user_id': 'user-b',
      'remote_path': 'user-b/${a.id}.jpg',
      'sync_status': SyncStatus.synced,
    });
    SharedPreferences.setMockInitialValues({});
    final marker = LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: SyncCursorStore.inMemory(),
      prefs: await SharedPreferences.getInstance(),
    );
    await marker.markAllForUpload('user-b');
    final row = await rowOf(a.id);
    expect(row['remote_path'], 'user-b/${a.id}.jpg');
    expect(row['user_id'], 'user-b');
  });

  test('signed out and in as another account during an upload: the old '
      "account's path is not recorded, and the file goes to the new "
      'folder', () async {
    final a = await add();
    SharedPreferences.setMockInitialValues({LocalUploadMarker.ownerKey: _uid});
    final marker = LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: SyncCursorStore.inMemory(),
      prefs: await SharedPreferences.getInstance(),
    );
    store.afterUpload = () async {
      store.afterUpload = null;
      await marker.markAllForUpload('user-b');
      uid = 'user-b';
    };
    final t = transfer();
    final report = await t.run();
    expect(report.uploaded, 0);
    final row = await rowOf(a.id);
    expect(row['remote_path'], isNull);
    expect(await local.pendingRemovals(), ['$_uid/${a.id}.jpg']);

    store.currentUserId = 'user-b';
    final next = await t.run();
    expect(next.uploaded, 1);
    expect((await rowOf(a.id))['remote_path'], 'user-b/${a.id}.jpg');
  });

  test('sweep alone deletes orphaned files, with no store, user or '
      'network', () async {
    final live = await add();
    final orphan = await files.write('gone.jpg', [5]);
    final old = now.subtract(const Duration(hours: 1));
    orphan.setLastModifiedSync(old);
    (await files.fileFor(live)).setLastModifiedSync(old);
    uid = null;
    online = false;

    final swept = await transfer(withStore: false).sweep();

    expect(swept, 1);
    expect(await files.listNames(), [live.fileName]);
  });
}
