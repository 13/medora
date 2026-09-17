import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/test_database.dart';

void main() {
  late DateTime now;
  late FakeServerCore core;
  late FakeSyncTable remote;
  late TableSync sync;
  var ids = 0;

  setUp(() async {
    ids = 0;
    await setUpTestDatabase();
    now = DateTime.utc(2026, 3, 5, 12);
    core = FakeServerCore(() => now);
    remote = FakeSyncTable(core, 'treatments');
    sync = TableSync(
      table: 'treatments',
      remote: remote,
      newWriteId: () => 'w${ids++}',
      now: () => now,
    );
  });
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> local(String id) async =>
      (await (await AppDatabase.instance.database).query(
        'treatments',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  Future<void> edit(String id, Map<String, Object?> values, DateTime at) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'treatments',
      {
        ...values,
        'sync_status': 'pending_update',
        'updated_at': at.toIso8601String(),
        'edited_at': at.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// A treatment made three days ago on a 0.3.0 device, pulled here.
  Future<void> warmUp() async {
    now = DateTime.utc(2026, 3, 2, 9);
    remote.seed({
      'id': 't1',
      'user_id': 'u',
      'name': 'Sinusitis',
      'start_date': '2026-03-02',
      'is_active': true,
      'sick_leave_from': '2026-03-02',
      'doctor': 'Dr. Rossi',
      'updated_at': '2026-03-02T09:00:00.000Z',
    });
    now = DateTime.utc(2026, 3, 5, 12);
    for (final row in core.page('treatments', horizon: core.horizon)) {
      await sync.applyPulled(row);
    }
  }

  test(
    'S1b: A ended it; B adds the certificate number offline, then syncs',
    () async {
      await warmUp();
      // A (another 0.4.0 device) ends the illness and closes the leave.
      remote.editFromOtherDevice('t1', {
        'end_date': '2026-03-05',
        'is_active': false,
        'sick_leave_to': '2026-03-05',
      }, editedAt: DateTime.utc(2026, 3, 5, 9));
      // B, offline, types the certificate number later.
      await edit('t1', {
        'sick_leave_ref': 'CERT-B',
      }, DateTime.utc(2026, 3, 5, 10));
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(result.conflicts, isEmpty);
      final server = remote.get('t1')!;
      expect(
        [
          server['is_active'],
          server['end_date'],
          server['sick_leave_to'],
          server['sick_leave_ref'],
        ],
        [false, '2026-03-05', '2026-03-05', 'CERT-B'],
      );
      expect(server['row_version'], 3);
      final row = await local('t1');
      expect(row['sync_status'], 'synced');
      expect(
        [row['is_active'], row['end_date'], row['sick_leave_ref']],
        [0, '2026-03-05', 'CERT-B'],
      );
      expect(row['sync_version'], 3);
      expect(row['sync_write_id'], isNull);
      // 1 failed patch, 1 fetch, 1 patch.
      expect(core.requests.where((r) => r.startsWith('treatments:')).toList(), [
        'treatments:legacy',
        'treatments:page',
        'treatments:patch',
        'treatments:patch',
        'treatments:fetch',
        'treatments:patch',
      ]);
    },
  );

  test('a lost answer is recognised as this device\'s own write', () async {
    await warmUp();
    await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
    remote.loseAnswerFor.add('t1');
    await expectLater(
      sync.pushRow(await local('t1'), userId: 'u'),
      throwsA(isA<TimeoutException>()),
    );
    expect((await local('t1'))['sync_write_id'], 'w0');
    // The next cycle: nothing is sent twice, the row settles.
    final before = core.requests.length;
    final result = await sync.pushRow(await local('t1'), userId: 'u');
    expect(result.outcome, PushOutcome.settled);
    expect(core.requests.sublist(before), ['treatments:fetch']);
    final row = await local('t1');
    expect(
      [row['sync_status'], row['sync_version'], row['sync_write_id']],
      ['synced', 2, null],
    );
  });

  test(
    'a lost answer, then a newer edit: only the newer edit goes out',
    () async {
      await warmUp();
      await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
      remote.loseAnswerFor.add('t1');
      await expectLater(
        sync.pushRow(await local('t1'), userId: 'u'),
        throwsA(isA<TimeoutException>()),
      );
      await edit('t1', {
        'doctor': 'Dr. Bianchi',
      }, DateTime.utc(2026, 3, 5, 10, 5));
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      final server = remote.get('t1')!;
      expect(
        [server['notes'], server['doctor'], server['row_version']],
        ['after food', 'Dr. Bianchi', 3],
      );
      expect(core.requests.last, 'treatments:patch');
    },
  );

  group('a lost answer, then the same field edited on a clock that '
      'stepped back', () {
    Future<void> loseThenEditEarlier() async {
      await warmUp();
      await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
      remote.loseAnswerFor.add('t1');
      await expectLater(
        sync.pushRow(await local('t1'), userId: 'u'),
        throwsA(isA<TimeoutException>()),
      );
      // The clock stepped back five minutes before the next edit.
      await edit('t1', {
        'notes': 'before food',
      }, DateTime.utc(2026, 3, 5, 9, 55));
    }

    test('the push: the newer edit goes out', () async {
      await loseThenEditEarlier();
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(result.conflicts, isEmpty);
      expect(remote.get('t1')!['notes'], 'before food');
      expect((await local('t1'))['notes'], 'before food');
    });

    test('the pull: the own write becomes the base, the newer edit stays '
        'pending', () async {
      final since = core.horizon;
      await loseThenEditEarlier();
      final applied = await sync.applyPulled(
        core.page('treatments', horizon: core.horizon, afterXid: since).single,
      );
      expect(applied.conflicts, isEmpty);
      final row = await local('t1');
      expect(
        [
          row['notes'],
          row['sync_status'],
          row['sync_version'],
          row['sync_write_id'],
        ],
        ['before food', 'pending_update', 2, null],
      );
      expect(LocalSyncMeta.fromRow(row).base!['notes'], 'after food');
    });
  });

  test('pull: a pending local edit merges with a newer server copy', () async {
    await warmUp();
    await edit('t1', {
      'sick_leave_ref': 'CERT-B',
    }, DateTime.utc(2026, 3, 5, 10));
    final horizon = core.horizon;
    remote.editFromOtherDevice('t1', {
      'end_date': '2026-03-05',
      'is_active': false,
    }, editedAt: DateTime.utc(2026, 3, 5, 9));
    final page = core.page(
      'treatments',
      horizon: core.horizon,
      afterXid: horizon,
    );
    final applied = await sync.applyPulled(page.single);
    expect(applied.outcome, PullOutcome.merged);
    final row = await local('t1');
    expect(
      [
        row['sync_status'],
        row['is_active'],
        row['sick_leave_ref'],
        row['sync_version'],
      ],
      ['pending_update', 0, 'CERT-B', 2],
    );
    // The push then sends only the certificate number.
    await sync.pushRow(await local('t1'), userId: 'u');
    expect(remote.get('t1')!['sick_leave_ref'], 'CERT-B');
    expect(remote.get('t1')!['row_version'], 3);
  });

  test('same field: the later edit wins, the other is reported', () async {
    await warmUp();
    remote.editFromOtherDevice('t1', {
      'sick_leave_ref': 'A',
    }, editedAt: DateTime.utc(2026, 3, 5, 10, 5));
    await edit('t1', {'sick_leave_ref': 'B'}, DateTime.utc(2026, 3, 5, 10, 7));
    final result = await sync.pushRow(await local('t1'), userId: 'u');
    expect(result.conflicts.single.keptLocal, isTrue);
    expect(remote.get('t1')!['sick_leave_ref'], 'B');
  });

  test('delete of a never-confirmed create leaves a tombstone', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('treatments', {
      'id': 't9',
      'name': 'Cold',
      'start_date': '2026-03-05',
      'is_active': 1,
      'updated_at': '2026-03-05T11:00:00.000Z',
      'sync_status': 'pending_delete',
      'sync_write_id': 'lost',
      'deleted_at': '2026-03-05T11:30:00.000Z',
    });
    await sync.pushRow(
      await db.query('treatments', where: "id = 't9'").then((r) => r.single),
      userId: 'u',
    );
    expect(remote.get('t9')!['deleted_at'], isNotNull);
    // The late insert lands and changes nothing.
    core.insertIfAbsent('treatments', [
      {
        'id': 't9',
        'user_id': 'u',
        'name': 'Cold',
        'start_date': '2026-03-05',
        'write_id': 'lost',
      },
    ]);
    expect(remote.get('t9')!['deleted_at'], isNotNull);
    expect(await db.query('treatments', where: "id = 't9'"), isEmpty);
  });

  test('force push brings back a row another device deleted', () async {
    await warmUp();
    remote.editFromOtherDevice('t1', {
      'deleted_at': '2026-03-05T09:00:00.000Z',
    }, editedAt: DateTime.utc(2026, 3, 5, 9));
    await edit('t1', {'notes': 'mine'}, DateTime.utc(2026, 3, 5, 10));
    final result = await sync.pushRow(
      await local('t1'),
      userId: 'u',
      force: true,
    );
    expect(result.outcome, PushOutcome.settled);
    final server = remote.get('t1')!;
    expect([server['deleted_at'], server['notes']], [null, 'mine']);
    final row = await local('t1');
    expect(
      [row['sync_status'], row['deleted_at'], row['notes']],
      ['synced', null, 'mine'],
    );
  });

  test('a person\'s delete pulled from another device wins over a pending '
      'edit here', () async {
    await warmUp();
    final horizon = core.horizon;
    await edit('t1', {'notes': 'mine'}, DateTime.utc(2026, 3, 5, 11));
    remote.editFromOtherDevice('t1', {
      'deleted_at': '2026-03-05T09:00:00.000Z',
    }, editedAt: DateTime.utc(2026, 3, 5, 9));
    final page = core.page(
      'treatments',
      horizon: core.horizon,
      afterXid: horizon,
    );
    final applied = await sync.applyPulled(page.single);
    expect(applied.outcome, PullOutcome.deleted);
    final db = await AppDatabase.instance.database;
    expect(await db.query('treatments'), isEmpty);
  });

  test('a pull of a row this device already holds changes nothing', () async {
    await warmUp();
    final row = await local('t1');
    final again = await sync.applyPulled(core.fetch('treatments', 't1')!);
    expect(again.outcome, PullOutcome.kept);
    expect(await local('t1'), row);
  });

  test('a pulled medication shows the server stock plus the changes still '
      'waiting here', () async {
    final meds = FakeSyncTable(core, 'medications');
    final medSync = TableSync(
      table: 'medications',
      remote: meds,
      newWriteId: () => 'm${ids++}',
      now: () => now,
    );
    meds.seed({'id': 'm1', 'user_id': 'u', 'name': 'Ibu', 'quantity': 10});
    await medSync.applyPulled(core.fetch('medications', 'm1')!);
    final db = await AppDatabase.instance.database;
    // A dose taken here, not sent yet.
    await db.transaction(
      (txn) => StockOutboxLocalDatasource.enqueue(
        txn,
        StockOp(
          opId: 'op1',
          medicationId: 'm1',
          delta: -1,
          createdAt: DateTime.utc(2026, 3, 5, 11),
        ),
      ),
    );
    await db.update('medications', {'quantity': 9});
    // Another device counted the pack: 20.
    core.applyStockChange(opId: 'other', medicationId: 'm1', setTo: 20);
    await medSync.applyPulled(core.fetch('medications', 'm1')!);
    expect((await db.query('medications')).single['quantity'], 19);
  });

  group('doses', () {
    late FakeSyncTable doses;
    late TableSync doseSync;
    setUp(() async {
      doses = FakeSyncTable(core, 'dose_logs');
      doseSync = TableSync(
        table: 'dose_logs',
        remote: doses,
        newWriteId: () => 'd${ids++}',
        now: () => now,
      );
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {
        'id': 'm1',
        'name': 'Ibu',
        'quantity': 10,
        'sync_status': 'synced',
      });
      await db.insert('treatments', {
        'id': 't1',
        'name': 'Flu',
        'start_date': '2026-03-01',
        'is_active': 1,
        'sync_status': 'synced',
      });
      await db.insert('prescriptions', {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1',
        'start_time': '2026-03-01T08:00:00.000',
        'sync_status': 'synced',
      });
      // A generated dose, inserted by another device, pulled here.
      core.insertIfAbsent('dose_logs', [
        {
          'id': 'd1',
          'prescription_id': 'p1',
          'scheduled_time': '2026-03-01T07:00:00.000Z',
          'status': 'pending',
          'updated_at': '1970-01-01T00:00:00.000Z',
          'write_id': 'gen',
          'edited_at': '1970-01-01T00:00:00.000Z',
        },
      ]);
      for (final row in core.page('dose_logs', horizon: core.horizon)) {
        await doseSync.applyPulled(row);
      }
    });

    Future<Map<String, Object?>> dose() async =>
        (await (await AppDatabase.instance.database).query(
          'dose_logs',
          where: "id = 'd1'",
        )).single;

    Future<void> localChange(Map<String, Object?> values) async {
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        ...values,
        'sync_status': 'pending_update',
      }, where: "id = 'd1'");
    }

    /// Pulls every dose row written since [after].
    Future<List<PullApplied>> pullDoses(int after) async => [
      for (final row in core.page(
        'dose_logs',
        horizon: core.horizon,
        afterXid: after,
      ))
        await doseSync.applyPulled(row),
    ];

    Future<void> takeHere(DateTime at) => localChange({
      'status': 'taken',
      'taken_time': at.toIso8601String(),
      'updated_at': at.toIso8601String(),
      'edited_at': at.toIso8601String(),
    });

    test('a take here beats an automatic missed pulled from another '
        'device', () async {
      final since = core.horizon;
      doses.editFromOtherDevice('d1', {
        'status': 'missed',
      }, editedAt: automaticEditedAt);
      await takeHere(DateTime.utc(2026, 3, 1, 7, 5));
      final applied = (await pullDoses(since)).single;
      expect(applied.outcome, PullOutcome.merged);
      expect(applied.conflicts.single.keptLocal, isTrue);
      expect(
        [(await dose())['status'], (await dose())['sync_status']],
        ['taken', 'pending_update'],
      );
      final result = await doseSync.pushRow(await dose(), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(doses.get('d1')!['status'], 'taken');
      expect((await dose())['sync_status'], 'synced');
    });

    test('a take here brings back a dose another device dropped', () async {
      final since = core.horizon;
      // The other device's schedule no longer has the slot: a guarded,
      // automatic delete.
      core.patch(
        'dose_logs',
        'd1',
        {
          'deleted_at': '2026-03-01T06:00:00.000Z',
          'write_id': 'other-drop',
          'edited_at': automaticEditedAt.toIso8601String(),
        },
        ifStatus: 'pending',
        ifLive: true,
      );
      await takeHere(DateTime.utc(2026, 3, 1, 7, 5));
      final applied = (await pullDoses(since)).single;
      expect(applied.outcome, PullOutcome.merged);
      final row = await dose();
      expect(
        [row['status'], row['sync_status'], row['deleted_at']],
        ['taken', 'pending_update', null],
      );
      await doseSync.pushRow(await dose(), userId: 'u');
      final server = doses.get('d1')!;
      expect([server['status'], server['deleted_at']], ['taken', null]);
      expect((await dose())['sync_status'], 'synced');
    });

    test('an automatic missed here and an automatic drop elsewhere: the '
        'drop wins', () async {
      final since = core.horizon;
      core.patch('dose_logs', 'd1', {
        'deleted_at': '2026-03-01T06:00:00.000Z',
        'write_id': 'other-drop',
        'edited_at': automaticEditedAt.toIso8601String(),
      }, ifStatus: 'pending');
      await localChange({
        'status': 'missed',
        'edited_at': automaticEditedAt.toIso8601String(),
      });
      expect((await pullDoses(since)).single.outcome, PullOutcome.deleted);
    });

    test('a dropped slot here and a take pulled from another device: the '
        'take is stored', () async {
      final since = core.horizon;
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
        'edited_at': automaticEditedAt.toIso8601String(),
      }, where: "id = 'd1'");
      doses.editFromOtherDevice('d1', {
        'status': 'taken',
        'taken_time': '2026-03-01T07:05:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      expect((await pullDoses(since)).single.outcome, PullOutcome.replaced);
      final row = await dose();
      expect(
        [row['status'], row['sync_status'], row['delete_guard']],
        ['taken', 'synced', null],
      );
    });

    group('a dose generated on both devices', () {
      setUp(() {
        // The other device generated d2 and sent it first.
        core.insertIfAbsent('dose_logs', [
          {
            'id': 'd2',
            'prescription_id': 'p1',
            'scheduled_time': '2026-03-01T15:00:00.000Z',
            'status': 'pending',
            'updated_at': '1970-01-01T00:00:00.000Z',
            'write_id': 'gen-other',
            'edited_at': '1970-01-01T00:00:00.000Z',
          },
        ]);
      });

      Future<Map<String, Object?>> d2() async =>
          (await (await AppDatabase.instance.database).query(
            'dose_logs',
            where: "id = 'd2'",
          )).single;

      Future<void> generateHere(Map<String, Object?> values) async {
        final db = await AppDatabase.instance.database;
        await db.insert('dose_logs', {
          'id': 'd2',
          'prescription_id': 'p1',
          'scheduled_time': DateTime.utc(
            2026,
            3,
            1,
            15,
          ).toLocal().toIso8601String(),
          'status': 'pending',
          'updated_at': '1970-01-01T00:00:00.000Z',
          'edited_at': '1970-01-01T00:00:00.000Z',
          'sync_status': 'pending_create',
          ...values,
        });
      }

      test('taken here before its create went out: the take wins', () async {
        final at = DateTime.utc(2026, 3, 1, 15, 10);
        await generateHere({
          'status': 'taken',
          'taken_time': at.toIso8601String(),
          'updated_at': at.toIso8601String(),
          'edited_at': at.toIso8601String(),
        });
        final result = await doseSync.pushRow(await d2(), userId: 'u');
        expect(result.outcome, PushOutcome.settled);
        expect(result.conflicts.single.keptLocal, isTrue);
        expect(doses.get('d2')!['status'], 'taken');
        final row = await d2();
        expect(
          [row['status'], row['sync_status'], row['sync_write_id']],
          ['taken', 'synced', null],
        );
      });

      test('taken elsewhere, still pending here: the take is kept', () async {
        doses.editFromOtherDevice('d2', {
          'status': 'taken',
          'taken_time': '2026-03-01T15:02:00.000Z',
        }, editedAt: DateTime.utc(2026, 3, 1, 15, 2));
        await generateHere({});
        final result = await doseSync.pushRow(await d2(), userId: 'u');
        expect(result.outcome, PushOutcome.settled);
        expect(doses.get('d2')!['status'], 'taken');
        final row = await d2();
        expect([row['status'], row['sync_status']], ['taken', 'synced']);
      });
    });

    test('automatic missed loses to a take made elsewhere', () async {
      doses.editFromOtherDevice('d1', {
        'status': 'taken',
        'taken_time': '2026-03-01T07:05:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      await localChange({
        'status': 'missed',
        'edited_at': automaticEditedAt.toIso8601String(),
      });
      final result = await doseSync.pushRow(await dose(), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(doses.get('d1')!['status'], 'taken');
      expect((await dose())['status'], 'taken');
      expect((await dose())['sync_status'], 'synced');
    });

    test('automatic missed lands as missed and keeps updated_at', () async {
      await localChange({
        'status': 'missed',
        'edited_at': automaticEditedAt.toIso8601String(),
      });
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(
        [
          doses.get('d1')!['status'],
          doses.get('d1')!['updated_at'],
          doses.get('d1')!['edited_at'],
        ],
        ['missed', '1970-01-01T00:00:00.000Z', '1970-01-01T00:00:00.000Z'],
      );
    });

    test(
      'a shifted time correction and a take elsewhere are both kept',
      () async {
        doses.editFromOtherDevice('d1', {
          'status': 'taken',
          'taken_time': '2026-03-01T07:05:00.000Z',
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
        await localChange({
          'scheduled_time': '2026-03-01T06:00:00.000',
          'edited_at': automaticEditedAt.toIso8601String(),
        });
        await doseSync.pushRow(await dose(), userId: 'u');
        final server = doses.get('d1')!;
        expect(
          [
            server['status'],
            DateTime.parse(server['scheduled_time'] as String).toUtc(),
          ],
          ['taken', DateTime.parse('2026-03-01T06:00:00.000').toUtc()],
        );
      },
    );

    test('a dropped slot is deleted only while pending', () async {
      doses.editFromOtherDevice('d1', {
        'status': 'taken',
        'taken_time': '2026-03-01T07:05:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
      }, where: "id = 'd1'");
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(doses.get('d1')!['deleted_at'], isNull);
      final row = await dose();
      expect(
        [row['status'], row['sync_status'], row['delete_guard']],
        ['taken', 'synced', null],
      );
    });

    test(
      'a dropped slot still pending is deleted on the server and here',
      () async {
        final db = await AppDatabase.instance.database;
        await db.update('dose_logs', {
          'sync_status': 'pending_delete',
          'delete_guard': 'if_pending',
        }, where: "id = 'd1'");
        await doseSync.pushRow(await dose(), userId: 'u');
        expect(doses.get('d1')!['deleted_at'], isNotNull);
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      },
    );
  });

  test('isAutomaticEdit', () {
    expect(isAutomaticEdit(automaticEditedAt), isTrue);
    expect(isAutomaticEdit(DateTime.utc(2026)), isFalse);
    expect(syncedTables, hasLength(4));
  });
}
