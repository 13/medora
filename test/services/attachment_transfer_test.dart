import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/repositories/attachment_repository_impl.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/attachment_import_result.dart';
import 'package:medora/services/attachment_transfer.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

const _uid = 'user-a';

/// A store whose uploads can be held open, or run a hook once stored.
class _GatedStore extends FakeAttachmentStore {
  _GatedStore() : super(currentUserId: _uid);

  Completer<void>? gate;
  Future<void> Function()? afterUpload;

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
    const a = Attachment(
      id: 'a9',
      ownerKind: AttachmentOwnerKind.rx,
      ownerId: 'r1',
      kind: AttachmentKind.photo,
      mime: 'image/jpeg',
      sizeBytes: 2,
      sha256: 'x',
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
}
