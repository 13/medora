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

  Map<String, Object?> rxRow(String id, {String status = 'pending_create'}) => {
    'id': id,
    'kind': 'ssn',
    'nre': '0410A1234567890',
    'issued_on': '2026-09-20',
    'items':
        '[{"id":"i1","description":"Brufen","packs":1,"non_substitutable":false}]',
    'cancelled': 0,
    'created_at': '2026-09-23T12:00:00.000Z',
    'updated_at': '2026-09-23T12:00:00.000Z',
    'edited_at': '2026-09-23T12:00:00.000Z',
    'sync_status': status,
  };

  test('a new rx is pushed and settles', () async {
    await (await db()).insert('rx', rxRow('r1'));
    final row = (await (await db()).query('rx')).single;
    final result = await syncOf('rx').pushRow(row, userId: 'u1');
    expect(result.outcome, PushOutcome.settled);
    expect(remote('rx').get('r1')!['user_id'], 'u1');
    expect(remote('rx').get('r1')!['items'], isA<List<dynamic>>());
    final local = (await (await db()).query('rx')).single;
    expect(local['sync_status'], SyncStatus.synced);
  });

  test('a pulled rx is stored with its items as text', () async {
    final server = remote('rx').seed({
      'id': 'r2',
      'user_id': 'u1',
      'kind': 'white_repeatable',
      'issued_on': '2026-09-01',
      'max_dispensings': 10,
      'items': [
        {'id': 'i1', 'description': 'X', 'packs': 1, 'non_substitutable': true},
      ],
      'cancelled': false,
    });
    final applied = await syncOf('rx').applyPulled(server);
    expect(applied.outcome, PullOutcome.inserted);
    final local = (await (await db()).query('rx')).single;
    expect(local['items'], contains('"non_substitutable":true'));
    expect(local['max_dispensings'], 10);
  });

  test("a white prescription's PIN is pushed and pulled", () async {
    await (await db()).insert('rx', {
      ...rxRow('w1'),
      'kind': 'white',
      'nre': 'G00001234567',
      'pin': '7XQ2K',
    });
    final row = (await (await db()).query('rx')).single;
    final pushed = await syncOf('rx').pushRow(row, userId: 'u1');
    expect(pushed.outcome, PushOutcome.settled);
    expect(remote('rx').get('w1')!['pin'], '7XQ2K');

    final server = remote('rx').seed({
      'id': 'w2',
      'user_id': 'u1',
      'kind': 'white',
      'nre': 'G00001234568',
      'pin': '8YR3L',
      'issued_on': '2026-09-01',
      'items': <Object?>[],
      'cancelled': false,
    });
    final applied = await syncOf('rx').applyPulled(server);
    expect(applied.outcome, PullOutcome.inserted);
    final local = await (await db()).query(
      'rx',
      where: 'id = ?',
      whereArgs: ['w2'],
    );
    expect(local.single['pin'], '8YR3L');
  });

  test('a dispensing under an rx deleted here goes with it', () async {
    await (await db()).insert('rx', {
      ...rxRow('r3', status: SyncStatus.pendingDelete),
      'deleted_at': '2026-09-23T12:00:00.000Z',
    });
    final server = remote('rx_dispensings').seed({
      'id': 'd1',
      'user_id': 'u1',
      'rx_id': 'r3',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-09-22',
      'units_added': 0,
    });
    final applied = await syncOf('rx_dispensings').applyPulled(server);
    expect(applied.outcome, PullOutcome.kept);
    expect(await (await db()).query('rx_dispensings'), isEmpty);
  });

  test('a dispensing whose rx has not arrived yet is orphaned', () async {
    final server = remote('rx_dispensings').seed({
      'id': 'd2',
      'user_id': 'u1',
      'rx_id': 'missing',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-09-22',
      'units_added': 0,
    });
    final applied = await syncOf('rx_dispensings').applyPulled(server);
    expect(applied.outcome, PullOutcome.orphaned);
  });

  test('a person edited on both sides merges by column', () async {
    final sync = syncOf('persons');
    await sync.applyPulled(
      remote(
        'persons',
      ).seed({'id': 'p1', 'user_id': 'u1', 'name': 'Ben', 'exemptions': '[]'}),
    );
    now = now.add(const Duration(minutes: 1));
    final server = remote('persons').editFromOtherDevice('p1', {
      'tax_code': 'RSSMRA85T10A562S',
    }, editedAt: now)!;
    await writeLocalChange(await db(), 'persons', 'p1', {
      'notes': 'Allergie: Penicillin',
      'sync_status': SyncStatus.pendingUpdate,
      'edited_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }, at: now);
    final applied = await sync.applyPulled(server);
    expect(applied.outcome, PullOutcome.merged);
    final local = (await (await db()).query('persons')).single;
    expect(local['tax_code'], 'RSSMRA85T10A562S');
    expect(local['notes'], 'Allergie: Penicillin');
  });
}
