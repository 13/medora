import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/domain/entities/attachment.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final at = DateTime(2026, 9, 24, 9);
  AttachmentModel model(String id, {String owner = 'r1', String? remote}) =>
      AttachmentModel(
        id: id,
        ownerKind: AttachmentOwnerKind.rx,
        ownerId: owner,
        kind: AttachmentKind.photo,
        mime: 'image/jpeg',
        sizeBytes: 1234,
        sha256: 'abc',
        originalName: 'IMG_1.jpg',
        remotePath: remote,
        createdAt: at,
        updatedAt: at,
      );

  test('a row round-trips and its wire copy equals the model', () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.upsert(model('a1'), syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('a1'))!;
    expect(back.ownerKind, AttachmentOwnerKind.rx);
    expect(back.kind, AttachmentKind.photo);
    expect(back.sizeBytes, 1234);
    final db = await AppDatabase.instance.database;
    final row = (await db.query('attachments')).single;
    expect(AttachmentLocalDatasource.wireOf(row), model('a1').toJson());
  });

  test(
    'owner listing hides tombstones; awaiting upload = no remote path',
    () async {
      final local = AttachmentLocalDatasource(now: () => at);
      await local.upsert(model('a1'), syncStatus: SyncStatus.pendingCreate);
      await local.upsert(
        model('a2', remote: 'u/a2.jpg'),
        syncStatus: SyncStatus.synced,
      );
      await local.upsert(
        model('a3', owner: 'r2'),
        syncStatus: SyncStatus.synced,
      );
      await local.markDeleted('a3');
      expect(
        (await local.getForOwner(
          AttachmentOwnerKind.rx,
          'r1',
        )).map((a) => a.id),
        unorderedEquals(['a1', 'a2']),
      );
      expect((await local.getAwaitingUpload()).map((a) => a.id), ['a1']);
      expect(await local.getAllIds(), unorderedEquals(['a1', 'a2', 'a3']));
    },
  );

  test('getForKind returns every live row of that kind, across owners, in '
      'one query', () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.upsert(model('a1'), syncStatus: SyncStatus.pendingCreate);
    await local.upsert(model('a2', owner: 'r2'), syncStatus: SyncStatus.synced);
    await local.upsert(model('a3', owner: 'r2'), syncStatus: SyncStatus.synced);
    await local.markDeleted('a3');
    expect(
      (await local.getForKind(AttachmentOwnerKind.rx)).map((a) => a.id),
      unorderedEquals(['a1', 'a2']),
    );
    expect(await local.getForKind(AttachmentOwnerKind.treatment), isEmpty);
  });

  test('the removal queue keeps each path once until completed', () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.enqueueRemoval('u/a1.jpg');
    await local.enqueueRemoval('u/a1.jpg');
    await local.enqueueRemoval('u/a2.pdf');
    expect(await local.pendingRemovals(), ['u/a1.jpg', 'u/a2.pdf']);
    await local.completeRemoval('u/a1.jpg');
    expect(await local.pendingRemovals(), ['u/a2.pdf']);
  });
}
