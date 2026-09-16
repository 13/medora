import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/push_settle.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  const pushed = '2026-03-04T11:58:00.000Z';
  final server = DateTime.utc(2026, 3, 4, 12);

  Future<void> insert({
    String updatedAt = pushed,
    String status = SyncStatus.pendingUpdate,
  }) async {
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'm1',
      'name': 'Tachipirina',
      'quantity': 1,
      'updated_at': updatedAt,
      'sync_status': status,
    });
  }

  Future<Map<String, Object?>?> row() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: ['m1'],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<bool> settle({DateTime? serverAt}) async => settlePushedRow(
    await AppDatabase.instance.database,
    'medications',
    id: 'm1',
    pushedUpdatedAt: pushed,
    serverUpdatedAt: serverAt,
  );

  test('an unchanged row is synced and takes the server stamp', () async {
    await insert();
    expect(await settle(serverAt: server), isFalse);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.synced);
    expect(DateTime.parse(r['updated_at']! as String), server);
  });

  test('an unchanged row keeps its stamp when the server sent none', () async {
    await insert();
    expect(await settle(), isFalse);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.synced);
    expect(r['updated_at'], pushed);
  });

  test('a row edited before the server stamp stays pending, stamped just '
      'after the push', () async {
    await insert(updatedAt: '2026-03-04T11:59:00.000Z');
    expect(await settle(serverAt: server), isTrue);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.pendingUpdate);
    expect(
      DateTime.parse(r['updated_at']! as String),
      server.add(const Duration(milliseconds: 1)),
    );
  });

  test('a row edited after the server stamp keeps its own stamp', () async {
    const later = '2026-03-04T12:05:00.000Z';
    await insert(updatedAt: later);
    expect(await settle(serverAt: server), isTrue);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.pendingUpdate);
    expect(r['updated_at'], later);
  });

  test('an edited row with no server stamp stays pending as it is', () async {
    const edited = '2026-03-04T11:59:00.000Z';
    await insert(updatedAt: edited);
    expect(await settle(), isTrue);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.pendingUpdate);
    expect(r['updated_at'], edited);
  });

  test('a row deleted meanwhile stays a pending delete', () async {
    await insert(status: SyncStatus.pendingDelete);
    expect(await settle(serverAt: server), isTrue);
    final r = (await row())!;
    expect(r['sync_status'], SyncStatus.pendingDelete);
    expect(r['updated_at'], pushed);
  });

  test('a changed row that is already synced again is left alone', () async {
    const pulled = '2026-03-04T11:59:00.000Z';
    await insert(updatedAt: pulled, status: SyncStatus.synced);
    expect(await settle(serverAt: server), isFalse);
    expect((await row())!['updated_at'], pulled);
  });

  test('a row that is gone is nothing to push', () async {
    expect(await settle(serverAt: server), isFalse);
    expect(await row(), isNull);
  });
}
