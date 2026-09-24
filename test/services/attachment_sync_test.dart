import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';

import '../helpers/test_database.dart';
import 'sync_service_test.dart' show Harness;

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Map<String, Object?> attachmentRow(String id, {String? remotePath}) => {
    'id': id,
    'owner_kind': 'person',
    'owner_id': 'p1',
    'kind': 'photo',
    'mime': 'image/jpeg',
    'size_bytes': 1234,
    'sha256': 'a' * 64,
    'original_name': 'scan.jpg',
    'remote_path': remotePath,
    'created_at': '2026-03-04T12:00:00.000Z',
    'updated_at': '2026-03-04T12:00:00.000Z',
    'edited_at': '2026-03-04T12:00:00.000Z',
    'sync_status': SyncStatus.pendingCreate,
  };

  Future<int> count(String table) async =>
      (await (await AppDatabase.instance.database).query(table)).length;

  test('an attachment row made here reaches the server', () async {
    final h = Harness();
    await (await AppDatabase.instance.database).insert(
      'attachments',
      attachmentRow('a1', remotePath: 'user-a/a1.jpg'),
    );

    final report = (await h.service.syncAll())!;

    expect(report.failures, isEmpty);
    final remote = h.attachments.rows.get('a1')!;
    expect(remote['user_id'], 'user-a');
    expect(remote['owner_kind'], 'person');
    expect(remote['remote_path'], 'user-a/a1.jpg');
    final local = (await (await AppDatabase.instance.database).query(
      'attachments',
    )).single;
    expect(local['sync_status'], SyncStatus.synced);
  });

  group("a prescription's attachment made on another device", () {
    Map<String, Object?> rxOnServer(String id, {String? deletedAt}) => {
      'id': id,
      'user_id': 'user-a',
      'kind': 'white',
      'issued_on': '2026-03-01',
      'items': <Object?>[],
      'cancelled': false,
      'deleted_at': deletedAt,
    };

    Map<String, Object?> onServer(String id) => {
      ...attachmentRow(id, remotePath: 'user-a/$id.jpg'),
      'owner_kind': 'rx',
      'owner_id': 'r1',
      'user_id': 'user-a',
    }..remove('sync_status');

    test('arrives with its prescription', () async {
      final h = Harness();
      h.rx.rx.seed(rxOnServer('r1'));
      h.attachments.rows.seed(onServer('a1'));

      await h.service.syncAll();

      final db = await AppDatabase.instance.database;
      expect((await db.query('rx')).single['id'], 'r1');
      expect((await db.query('attachments')).single['id'], 'a1');
    });

    test('is passed over when the prescription is deleted on the '
        'server', () async {
      final h = Harness();
      h.rx.rx.seed(rxOnServer('r1', deletedAt: '2026-03-04T13:00:00.000Z'));
      // Stored live before the prescription's delete reached the server.
      h.attachments.rows.seed(onServer('a1'));

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      expect(await count('attachments'), 0);
    });

    test('goes here when the prescription is deleted on another device, '
        'and its object is queued for removal', () async {
      final h = Harness();
      h.rx.rx.seed(rxOnServer('r1'));
      h.attachments.rows.seed(onServer('a1'));
      await h.service.syncAll();
      expect(await count('attachments'), 1);

      h.rx.rx.editFromOtherDevice('r1', {
        'deleted_at': '2026-03-04T13:00:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 4, 13));
      await h.service.syncAll();

      final db = await AppDatabase.instance.database;
      expect(await count('rx'), 0);
      expect(await count('attachments'), 0);
      expect(
        (await db.query('attachment_removals')).single['remote_path'],
        'user-a/a1.jpg',
      );
    });
  });

  test('discarding a stuck prescription the server has deleted takes its '
      'attachments here too', () async {
    final h = Harness();
    final db = await AppDatabase.instance.database;
    h.rx.rx.seed({
      'id': 'r1',
      'user_id': 'user-a',
      'kind': 'white',
      'issued_on': '2026-03-01',
      'items': <Object?>[],
      'cancelled': false,
      'deleted_at': '2026-03-04T13:00:00.000Z',
    });
    await db.insert('rx', {
      'id': 'r1',
      'kind': 'white',
      'issued_on': '2026-03-01',
      'items': '[]',
      'cancelled': 0,
      'created_at': '2026-03-04T12:00:00.000Z',
      'updated_at': '2026-03-04T12:00:00.000Z',
      'sync_status': SyncStatus.pendingUpdate,
    });
    await db.insert('attachments', {
      ...attachmentRow('a1', remotePath: 'user-a/a1.jpg'),
      'owner_kind': 'rx',
      'owner_id': 'r1',
      'sync_status': SyncStatus.synced,
    });

    await h.service.discardFailedRow('rx', 'r1');

    expect(await count('rx'), 0);
    expect(await count('attachments'), 0);
    expect(
      (await db.query('attachment_removals')).single['remote_path'],
      'user-a/a1.jpg',
    );
  });

  test('an attachment row made on another device arrives here', () async {
    final h = Harness();
    h.attachments.rows.seed(
      {
        ...attachmentRow('a9', remotePath: 'user-a/a9.pdf'),
        'kind': 'pdf',
        'mime': 'application/pdf',
        'user_id': 'user-a',
      }..remove('sync_status'),
    );

    await h.service.syncAll();

    final row = (await (await AppDatabase.instance.database).query(
      'attachments',
    )).single;
    expect(row['id'], 'a9');
    expect(row['remote_path'], 'user-a/a9.pdf');
    expect(row['sync_status'], SyncStatus.synced);
  });

  test('discarding a stuck attachment row keeps the server copy', () async {
    final h = Harness();
    final db = await AppDatabase.instance.database;
    await db.insert('attachments', attachmentRow('a1'));
    await h.service.syncAll();
    await db.update(
      'attachments',
      {'original_name': 'stuck', 'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: ['a1'],
    );

    await h.service.discardFailedRow('attachments', 'a1');

    final row = (await db.query('attachments')).single;
    expect(row['original_name'], 'scan.jpg');
    expect(row['sync_status'], SyncStatus.synced);
  });

  test(
    'a force pull replaces the attachment rows with the server\'s',
    () async {
      final h = Harness();
      h.attachments.rows.seed(
        {...attachmentRow('server'), 'user_id': 'user-a'}
          ..remove('sync_status'),
      );
      final db = await AppDatabase.instance.database;
      await db.insert('attachments', {
        ...attachmentRow('local-only'),
        'sync_status': SyncStatus.synced,
      });
      await db.insert('attachment_removals', {
        'remote_path': 'user-a/old.jpg',
        'created_at': '2026-03-04T12:00:00.000Z',
      });

      final report = (await h.service.forcePull())!;

      expect(report.fatal, isNull);
      expect((await db.query('attachments')).map((r) => r['id']).toList(), [
        'server',
      ]);
      expect(await count('attachment_removals'), 0);
    },
  );

  group('a project without the attachments migration', () {
    test(
      'a force pull keeps the attachments here and re-pulls the rest',
      () async {
        final h = Harness();
        h.attachments.dropTable();
        h.meds.table.seed(
          const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
        );
        final db = await AppDatabase.instance.database;
        await db.insert('attachments', attachmentRow('a1'));
        await db.insert('attachment_removals', {
          'remote_path': 'user-a/old.jpg',
          'created_at': '2026-03-04T12:00:00.000Z',
        });
        await db.insert('medications', {
          'id': 'local-only',
          'name': 'Gone',
          'quantity': 1,
          'quantity_unit': 'tablets',
          'is_archived': 0,
          'created_at': '2026-03-04T12:00:00.000Z',
          'updated_at': '2026-03-04T12:00:00.000Z',
          'sync_status': SyncStatus.synced,
        });

        final report = (await h.service.forcePull())!;

        expect(report.fatal, isNull);
        expect((await db.query('medications')).map((r) => r['id']).toList(), [
          'a',
        ]);
        // Never uploaded: wiping them would lose them for good.
        final kept = (await db.query('attachments')).single;
        expect(kept['id'], 'a1');
        expect(kept['sync_status'], SyncStatus.pendingCreate);
        expect(await count('attachment_removals'), 1);
        expect(
          report.failures.any(
            (f) =>
                f.table == 'attachments' &&
                f.error.contains('20260924000000_attachments.sql'),
          ),
          isTrue,
        );
      },
    );

    test('a force pull without the rx tables keeps both', () async {
      final h = Harness();
      h.rx.dropTables();
      h.attachments.dropTable();
      final db = await AppDatabase.instance.database;
      await db.insert('attachments', attachmentRow('a1'));
      await db.insert('persons', {
        'id': 'p1',
        'name': 'Ben',
        'exemptions': '[]',
        'created_at': '2026-03-04T12:00:00.000Z',
        'updated_at': '2026-03-04T12:00:00.000Z',
        'sync_status': SyncStatus.pendingCreate,
      });

      final report = (await h.service.forcePull())!;

      expect(report.fatal, isNull);
      expect(await count('attachments'), 1);
      expect(await count('persons'), 1);
    });

    test('an ordinary sync keeps the rows and names the migration', () async {
      final h = Harness();
      h.attachments.dropTable();
      await (await AppDatabase.instance.database).insert(
        'attachments',
        attachmentRow('a1'),
      );

      final report = (await h.service.syncAll())!;

      expect(report.fatal, isNull);
      expect(
        report.failures.any(
          (f) =>
              f.table == 'attachments' &&
              f.error.contains('20260924000000_attachments.sql'),
        ),
        isTrue,
      );
      expect(await count('attachments'), 1);
    });
  });
}
