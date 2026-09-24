import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:sqflite/sqflite.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/local_write.dart';
import '../../helpers/test_database.dart';

void main() {
  late DateTime now;
  late FakeServerCore core;
  var ids = 0;
  final remotes = <String, FakeSyncTable>{};

  FakeSyncTable remote(String table) =>
      remotes.putIfAbsent(table, () => FakeSyncTable(core, table));

  TableSync syncOf(String table) => TableSync(
    table: table,
    remote: remote(table),
    newWriteId: () => 'w${ids++}',
    now: () => now,
    currentUserId: () => 'u1',
  );

  setUp(() async {
    ids = 0;
    remotes.clear();
    await setUpTestDatabase();
    now = DateTime.utc(2026, 9, 23, 12);
    core = FakeServerCore(() => now);
  });
  tearDown(tearDownTestDatabase);

  Future<Database> db() => AppDatabase.instance.database;

  Map<String, Object?> attachmentRow(
    String id, {
    String status = 'pending_create',
    String? remotePath,
  }) => {
    'id': id,
    'owner_kind': 'rx',
    'owner_id': 'r1',
    'kind': 'photo',
    'mime': 'image/jpeg',
    'size_bytes': 12345,
    'sha256': 'a' * 64,
    'original_name': 'scan.jpg',
    'remote_path': remotePath,
    'created_at': '2026-09-23T12:00:00.000Z',
    'updated_at': '2026-09-23T12:00:00.000Z',
    'edited_at': '2026-09-23T12:00:00.000Z',
    'sync_status': status,
  };

  Future<List<String>> removals() async => [
    for (final r in await (await db()).query(
      'attachment_removals',
      orderBy: 'remote_path',
    ))
      r['remote_path']! as String,
  ];

  Future<void> insertRx(String id, {String status = SyncStatus.synced}) async =>
      (await db()).insert('rx', {
        'id': id,
        'kind': 'ssn',
        'issued_on': '2026-09-20',
        'items': '[]',
        'cancelled': 0,
        'created_at': '2026-09-23T12:00:00.000Z',
        'updated_at': '2026-09-23T12:00:00.000Z',
        'edited_at': '2026-09-23T12:00:00.000Z',
        if (status == SyncStatus.pendingDelete)
          'deleted_at': '2026-09-23T12:00:00.000Z',
        'sync_status': status,
      });

  Map<String, Object?> serverRow(
    String id, {
    String ownerKind = 'rx',
    String ownerId = 'r1',
  }) => {
    'id': id,
    'user_id': 'u1',
    'owner_kind': ownerKind,
    'owner_id': ownerId,
    'kind': 'photo',
    'mime': 'image/jpeg',
    'size_bytes': 10,
    'sha256': 'd' * 64,
    'remote_path': 'u1/$id.jpg',
  };

  group("a prescription's attachments", () {
    test('name the prescription as their parent; other owners are soft', () {
      expect(parentsOf('attachments', {'owner_kind': 'rx', 'owner_id': 'r1'}), [
        ('rx', 'r1'),
      ]);
      for (final kind in ['treatment', 'person']) {
        expect(
          parentsOf('attachments', {'owner_kind': kind, 'owner_id': 'r1'}),
          isEmpty,
        );
      }
    });

    test(
      'one pulled under a prescription deleted here is not stored',
      () async {
        await insertRx('r1', status: SyncStatus.pendingDelete);
        final applied = await syncOf(
          'attachments',
        ).applyPulled(remote('attachments').seed(serverRow('a1')));
        expect(applied.outcome, PullOutcome.kept);
        expect(await (await db()).query('attachments'), isEmpty);
      },
    );

    test('one whose prescription has not arrived is orphaned', () async {
      final applied = await syncOf(
        'attachments',
      ).applyPulled(remote('attachments').seed(serverRow('a1')));
      expect(applied.outcome, PullOutcome.orphaned);
    });

    test('a pulled prescription tombstone takes its attachments here and '
        "queues their objects in this user's folder", () async {
      await insertRx('r1');
      await (await db()).insert('attachments', {
        ...attachmentRow('a1', status: SyncStatus.synced),
        'remote_path': 'u1/a1.jpg',
      });
      await (await db()).insert('attachments', {...attachmentRow('a2')});
      // Another account's object: not this user's to remove.
      await (await db()).insert('attachments', {
        ...attachmentRow('a3', status: SyncStatus.synced),
        'remote_path': 'u2/a3.jpg',
      });
      // A treatment's attachment that happens to name the same id stays.
      await (await db()).insert('attachments', {
        ...attachmentRow('t1', status: SyncStatus.synced),
        'owner_kind': 'treatment',
        'remote_path': 'u1/t1.jpg',
      });
      final server = remote('rx').seed({
        'id': 'r1',
        'user_id': 'u1',
        'kind': 'ssn',
        'issued_on': '2026-09-20',
        'items': <Object?>[],
        'cancelled': false,
        'deleted_at': '2026-09-23T13:00:00.000Z',
      });

      final applied = await syncOf('rx').applyPulled(server);

      expect(applied.outcome, PullOutcome.deleted);
      expect((await (await db()).query('attachments')).map((r) => r['id']), [
        't1',
      ]);
      expect(await removals(), ['u1/a1.jpg']);
    });

    test("a pulled attachment tombstone queues its object in this user's "
        'folder', () async {
      await insertRx('r1');
      final sync = syncOf('attachments');
      await sync.applyPulled(remote('attachments').seed(serverRow('a1')));
      now = now.add(const Duration(minutes: 1));
      final tombstone = remote('attachments').editFromOtherDevice('a1', {
        'deleted_at': now.toIso8601String(),
      }, editedAt: now)!;

      final applied = await sync.applyPulled(tombstone);

      expect(applied.outcome, PullOutcome.deleted);
      expect(await (await db()).query('attachments'), isEmpty);
      expect(await removals(), ['u1/a1.jpg']);
    });

    test('one pushed under a prescription deleted on the server is stored '
        'deleted: it goes here and its object is queued', () async {
      await insertRx('r1');
      remote('rx').seed({
        'id': 'r1',
        'user_id': 'u1',
        'kind': 'ssn',
        'issued_on': '2026-09-20',
        'items': <Object?>[],
        'cancelled': false,
        'deleted_at': '2026-09-23T11:00:00.000Z',
      });
      await (await db()).insert('attachments', {
        ...attachmentRow('a1'),
        'remote_path': 'u1/a1.jpg',
      });
      final row = (await (await db()).query('attachments')).single;

      final result = await syncOf('attachments').pushRow(row, userId: 'u1');

      expect(result.outcome, PushOutcome.settled);
      expect(remote('attachments').get('a1')!['deleted_at'], isNotNull);
      expect(await (await db()).query('attachments'), isEmpty);
      expect(await removals(), ['u1/a1.jpg']);
    });

    test('a pending one under a prescription deleted here is dropped '
        'unsent, and its object is queued', () async {
      await insertRx('r1', status: SyncStatus.pendingDelete);
      await (await db()).insert('attachments', {
        ...attachmentRow('a1'),
        'remote_path': 'u1/a1.jpg',
      });
      final row = (await (await db()).query('attachments')).single;

      final result = await syncOf('attachments').pushRow(row, userId: 'u1');

      expect(result.outcome, PushOutcome.settled);
      expect(remote('attachments').get('a1'), isNull);
      expect(await (await db()).query('attachments'), isEmpty);
      expect(await removals(), ['u1/a1.jpg']);
    });
  });

  test('a new attachment is pushed and settles', () async {
    await insertRx('r1');
    await (await db()).insert('attachments', attachmentRow('a1'));
    final row = (await (await db()).query('attachments')).single;
    final result = await syncOf('attachments').pushRow(row, userId: 'u1');
    expect(result.outcome, PushOutcome.settled);
    expect(remote('attachments').get('a1')!['user_id'], 'u1');
    expect(remote('attachments').get('a1')!['remote_path'], isNull);
    final local = (await (await db()).query('attachments')).single;
    expect(local['sync_status'], SyncStatus.synced);
  });

  test('a pulled attachment with a remote path is stored', () async {
    await insertRx('r1');
    final server = remote('attachments').seed({
      'id': 'a2',
      'user_id': 'u1',
      'owner_kind': 'rx',
      'owner_id': 'r1',
      'kind': 'photo',
      'mime': 'image/jpeg',
      'size_bytes': 999,
      'sha256': 'b' * 64,
      'remote_path': 'u1/a2.jpg',
    });
    final applied = await syncOf('attachments').applyPulled(server);
    expect(applied.outcome, PullOutcome.inserted);
    final local = (await (await db()).query('attachments')).single;
    expect(local['remote_path'], 'u1/a2.jpg');
  });

  test(
    'a local remote_path upload merges with an unrelated concurrent change',
    () async {
      await insertRx('r1');
      final sync = syncOf('attachments');
      await sync.applyPulled(
        remote('attachments').seed({
          'id': 'a3',
          'user_id': 'u1',
          'owner_kind': 'rx',
          'owner_id': 'r1',
          'kind': 'photo',
          'mime': 'image/jpeg',
          'size_bytes': 111,
          'sha256': 'c' * 64,
        }),
      );
      now = now.add(const Duration(minutes: 1));
      final server = remote('attachments').editFromOtherDevice('a3', {
        'original_name': 'renamed.jpg',
      }, editedAt: now)!;
      await writeLocalChange(await db(), 'attachments', 'a3', {
        'remote_path': 'u1/a3.jpg',
        'sync_status': SyncStatus.pendingUpdate,
        'edited_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }, at: now);
      final applied = await sync.applyPulled(server);
      expect(applied.outcome, anyOf(PullOutcome.merged, PullOutcome.replaced));
      final local = (await (await db()).query('attachments')).single;
      expect(local['remote_path'], 'u1/a3.jpg');
      expect(local['original_name'], 'renamed.jpg');
    },
  );
}
