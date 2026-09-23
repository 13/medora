import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/data/repositories/attachment_repository_impl.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/attachment_import.dart';

import '../../helpers/test_database.dart';

/// A datasource on which a delete lands right after [getById] returns.
class _RacingLocal extends AttachmentLocalDatasource {
  _RacingLocal({super.now});

  String? deleteAfterRead;

  @override
  Future<AttachmentModel?> getById(String id) async {
    final row = await super.getById(id);
    if (deleteAfterRead == id) {
      deleteAfterRead = null;
      await markDeleted(id);
    }
    return row;
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 24, 9);
  late Directory root;
  late AttachmentFiles files;
  late AttachmentLocalDatasource local;
  late AttachmentRepositoryImpl repo;
  var syncs = 0;

  setUp(() async {
    syncs = 0;
    root = await Directory.systemTemp.createTemp('att-repo');
    files = AttachmentFiles(rootDirectory: () async => root);
    local = AttachmentLocalDatasource(now: () => now);
    repo = AttachmentRepositoryImpl(
      local: local,
      files: files,
      requestSync: () async => syncs++,
      now: () => now,
    );
  });
  tearDown(() => root.delete(recursive: true));

  Imported imported({List<int> bytes = const [1, 2, 3]}) => Imported(
    kind: AttachmentKind.photo,
    mime: 'image/jpeg',
    bytes: Uint8List.fromList(bytes),
    sha256: 'abc',
    originalName: 'IMG_1.jpg',
  );

  test(
    'add writes the file first and stores a pending row awaiting upload',
    () async {
      final result = await repo.add(AttachmentOwnerKind.rx, 'r1', imported());
      expect(result.isSuccess, isTrue);
      final attachment = result.dataOrNull!;
      expect(attachment.remotePath, isNull);
      expect(attachment.sizeBytes, 3);
      final file = await files.fileFor(attachment);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), [1, 2, 3]);
      final db = await AppDatabase.instance.database;
      final row = (await db.query('attachments')).single;
      expect(row['sync_status'], SyncStatus.pendingCreate);
      expect(row['remote_path'], isNull);
      await Future<void>.delayed(Duration.zero);
      expect(syncs, 1);
    },
  );

  test(
    'countsForKind counts by owner, in one query, and ignores other kinds',
    () async {
      await repo.add(AttachmentOwnerKind.rx, 'r1', imported());
      await repo.add(AttachmentOwnerKind.rx, 'r1', imported());
      await repo.add(AttachmentOwnerKind.rx, 'r2', imported());
      await repo.add(AttachmentOwnerKind.treatment, 't1', imported());
      final result = await repo.countsForKind(AttachmentOwnerKind.rx);
      expect(result.isSuccess, isTrue);
      expect(result.dataOrNull, {'r1': 2, 'r2': 1});
    },
  );

  test('deleting an uploaded attachment tombstones it, removes the file and '
      'queues its path', () async {
    final added = (await repo.add(
      AttachmentOwnerKind.rx,
      'r1',
      imported(),
    )).dataOrNull!;
    await local.upsert(
      (await local.getById(
        added.id,
      ))!.copyWith(remotePath: 'u1/${added.fileName}'),
      syncStatus: SyncStatus.synced,
    );

    final result = await repo.delete(added.id);

    expect(result.isSuccess, isTrue);
    final row = await local.getById(added.id);
    expect(row!.deletedAt, isNotNull);
    expect(await files.has(added), isFalse);
    expect(await local.pendingRemovals(), ['u1/${added.fileName}']);
  });

  test('deleting a never-uploaded attachment queues nothing', () async {
    final added = (await repo.add(
      AttachmentOwnerKind.rx,
      'r1',
      imported(),
    )).dataOrNull!;

    final result = await repo.delete(added.id);

    expect(result.isSuccess, isTrue);
    expect(await files.has(added), isFalse);
    expect(await local.pendingRemovals(), isEmpty);
  });

  test('deleting an unknown attachment fails', () async {
    final result = await repo.delete('missing');
    expect(result.isFailure, isTrue);
  });

  test(
    'markUploaded on a live row sets remote_path and asks for a sync',
    () async {
      final added = (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        imported(),
      )).dataOrNull!;
      syncs = 0;

      final result = await repo.markUploaded(
        added.id,
        'u1/${added.fileName}',
        signedInUserId: 'u1',
      );

      expect(result.isSuccess, isTrue);
      expect(result.dataOrNull, isTrue);
      final row = await local.getById(added.id);
      expect(row!.remotePath, 'u1/${added.fileName}');
      final db = await AppDatabase.instance.database;
      expect(
        (await db.query('attachments')).single['sync_status'],
        SyncStatus.pendingUpdate,
      );
      await Future<void>.delayed(Duration.zero);
      expect(syncs, 1);
    },
  );

  test(
    'markUploaded on a deleted row is refused and queues the path',
    () async {
      final added = (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        imported(),
      )).dataOrNull!;
      await repo.delete(added.id);

      final result = await repo.markUploaded(
        added.id,
        'u1/${added.fileName}',
        signedInUserId: 'u1',
      );

      expect(result.isSuccess, isTrue);
      expect(result.dataOrNull, isFalse);
      expect(await local.pendingRemovals(), contains('u1/${added.fileName}'));
    },
  );

  test("markUploaded refuses a path whose last segment isn't the attachment's "
      'file name', () async {
    final added = (await repo.add(
      AttachmentOwnerKind.rx,
      'r1',
      imported(),
    )).dataOrNull!;

    final result = await repo.markUploaded(
      added.id,
      'u1/other.jpg',
      signedInUserId: 'u1',
    );

    expect(result.isFailure, isTrue);
    final row = await local.getById(added.id);
    expect(row!.remotePath, isNull);
  });

  test(
    'deleteForOwner tombstones every live attachment of the owner',
    () async {
      final a1 = (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        imported(),
      )).dataOrNull!;
      final a2 = (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        imported(),
      )).dataOrNull!;
      final other = (await repo.add(
        AttachmentOwnerKind.rx,
        'r2',
        imported(),
      )).dataOrNull!;

      final result = await repo.deleteForOwner(AttachmentOwnerKind.rx, 'r1');

      expect(result.isSuccess, isTrue);
      expect((await local.getById(a1.id))!.deletedAt, isNotNull);
      expect((await local.getById(a2.id))!.deletedAt, isNotNull);
      expect((await local.getById(other.id))!.deletedAt, isNull);
      final remaining = await repo.forOwner(AttachmentOwnerKind.rx, 'r1');
      expect(remaining.dataOrNull, isEmpty);
    },
  );

  test('markUploaded does not revive a row deleted after it was read; the '
      'object is queued for removal', () async {
    final racing = _RacingLocal(now: () => now);
    final r = AttachmentRepositoryImpl(
      local: racing,
      files: files,
      now: () => now,
    );
    final added = (await r.add(
      AttachmentOwnerKind.rx,
      'r1',
      imported(),
    )).dataOrNull!;
    final path = 'u1/${added.fileName}';
    racing.deleteAfterRead = added.id;

    final result = await r.markUploaded(added.id, path, signedInUserId: 'u1');

    expect(result.dataOrNull, isFalse);
    final row = (await (await AppDatabase.instance.database).query(
      'attachments',
    )).single;
    expect(row['deleted_at'], isNotNull);
    expect(row['sync_status'], SyncStatus.pendingDelete);
    expect(row['remote_path'], isNull);
    expect(await racing.pendingRemovals(), [path]);
  });

  test('markUploaded of a row that is gone queues the object', () async {
    final result = await repo.markUploaded(
      'nope',
      'u1/nope.jpg',
      signedInUserId: 'u1',
    );
    expect(result.dataOrNull, isFalse);
    expect(await local.pendingRemovals(), ['u1/nope.jpg']);
  });

  group('markUploaded accepts only a path in the owner\'s folder', () {
    Future<Attachment> addOwnedBy(String? userId) async {
      final added = (await repo.add(
        AttachmentOwnerKind.rx,
        'r1',
        imported(),
      )).dataOrNull!;
      await (await AppDatabase.instance.database).update(
        'attachments',
        {'user_id': userId},
        where: 'id = ?',
        whereArgs: [added.id],
      );
      return added;
    }

    test("a row of u1 refuses a path in u2's folder and queues it", () async {
      final added = await addOwnedBy('u1');
      final path = 'u2/${added.fileName}';

      final result = await repo.markUploaded(
        added.id,
        path,
        signedInUserId: 'u2',
      );

      expect(result.dataOrNull, isFalse);
      expect((await local.getById(added.id))!.remotePath, isNull);
      expect(await local.pendingRemovals(), [path]);
    });

    test('a row of u1 takes a path in its own folder, whoever is signed '
        'in', () async {
      final added = await addOwnedBy('u1');
      final path = 'u1/${added.fileName}';

      final result = await repo.markUploaded(
        added.id,
        path,
        signedInUserId: 'u1',
      );

      expect(result.dataOrNull, isTrue);
      expect((await local.getById(added.id))!.remotePath, path);
    });

    test('a row without an owner (cleared for another account) refuses the '
        "previous account's path", () async {
      final added = await addOwnedBy(null);
      final path = 'u1/${added.fileName}';

      final result = await repo.markUploaded(
        added.id,
        path,
        signedInUserId: 'u2',
      );

      expect(result.dataOrNull, isFalse);
      expect((await local.getById(added.id))!.remotePath, isNull);
      expect(await local.pendingRemovals(), [path]);
    });

    test(
      'a row without an owner and nobody signed in refuses the path',
      () async {
        final added = await addOwnedBy(null);
        final path = 'u1/${added.fileName}';

        final result = await repo.markUploaded(
          added.id,
          path,
          signedInUserId: null,
        );

        expect(result.dataOrNull, isFalse);
        expect((await local.getById(added.id))!.remotePath, isNull);
        expect(await local.pendingRemovals(), [path]);
      },
    );
  });
}
