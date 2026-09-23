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

  test('a new attachment is pushed and settles', () async {
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
