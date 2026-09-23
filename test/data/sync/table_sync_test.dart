import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/local_write.dart';
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
    await writeLocalChange(db, 'treatments', id, {
      ...values,
      'sync_status': 'pending_update',
      'updated_at': at.toIso8601String(),
      'edited_at': at.toIso8601String(),
    }, at: at);
  }

  FieldTimes serverTimes(String id) =>
      FieldTimes.decode(remote.get(id)!['field_edited_at']);

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

  group('the stock of a medication', () {
    late FakeSyncTable meds;
    late TableSync medSync;
    setUp(() {
      meds = FakeSyncTable(core, 'medications');
      medSync = TableSync(
        table: 'medications',
        remote: meds,
        newWriteId: () => 'm${ids++}',
        now: () => now,
      );
    });

    Future<Map<String, Object?>> med() async =>
        (await (await AppDatabase.instance.database).query(
          'medications',
          where: "id = 'm1'",
        )).single;

    /// A stock change made here: the quantity and its change together.
    Future<void> change(String opId, int delta) async {
      final db = await AppDatabase.instance.database;
      await db.transaction((txn) async {
        await txn.rawUpdate(
          "UPDATE medications SET quantity = quantity + ? WHERE id = 'm1'",
          [delta],
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          StockOp(
            opId: opId,
            medicationId: 'm1',
            delta: delta,
            createdAt: DateTime.utc(2026, 3, 5, 11),
          ),
        );
      });
    }

    Future<List<String>> waiting() async => [
      for (final op in await StockOutboxLocalDatasource().pending()) op.opId,
    ];

    /// Made here offline with 5, then restocked with 10 before its first
    /// sync.
    Future<void> createdAndRestocked() async {
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {
        'id': 'm1',
        'name': 'Moment',
        'quantity': 5,
        'created_at': '2026-03-05T10:00:00.000Z',
        'updated_at': '2026-03-05T10:00:00.000Z',
        'edited_at': '2026-03-05T10:00:00.000Z',
        'sync_status': 'pending_create',
      });
      await change('restock', 10);
    }

    test('a new medication goes out with its quantity, and the changes it '
        'already holds are not sent again', () async {
      await createdAndRestocked();

      final result = await medSync.pushRow(await med(), userId: 'u');

      expect(result.outcome, PushOutcome.settled);
      expect(meds.get('m1')!['quantity'], 15);
      expect(core.ledger, isEmpty);
      expect(await waiting(), isEmpty);
      final row = await med();
      expect([row['quantity'], row['sync_status']], [15, 'synced']);
    });

    test('a new medication whose insert answer is lost is not counted twice '
        'when its write is found again', () async {
      await createdAndRestocked();
      meds.loseAnswerFor.add('m1');

      await expectLater(
        medSync.pushRow(await med(), userId: 'u'),
        throwsA(isA<TimeoutException>()),
      );
      expect(meds.get('m1')!['quantity'], 15);
      expect(await waiting(), isEmpty);

      final result = await medSync.pushRow(await med(), userId: 'u');

      expect(result.outcome, PushOutcome.settled);
      expect(meds.get('m1')!['quantity'], 15);
      expect(core.ledger, isEmpty);
      final row = await med();
      expect([row['quantity'], row['sync_status']], [15, 'synced']);
      expect(row['sync_write_id'], isNull);
    });

    test('a new medication whose insert never lands is sent again with the '
        'same quantity', () async {
      await createdAndRestocked();
      meds.failIds.add('m1');

      await expectLater(
        medSync.pushRow(await med(), userId: 'u'),
        throwsA(isA<StateError>()),
      );
      expect(meds.get('m1'), isNull);
      expect((await med())['quantity'], 15);

      meds.failIds.clear();
      await medSync.pushRow(await med(), userId: 'u');
      expect(meds.get('m1')!['quantity'], 15);
      expect((await med())['quantity'], 15);
      expect(core.ledger, isEmpty);
    });

    test('a stock change made while the insert is in flight waits and stays '
        'on top', () async {
      await createdAndRestocked();
      var held = false;
      meds.beforeCall = () async {
        if (held) return;
        held = true;
        await change('taken', -1);
      };

      final result = await medSync.pushRow(await med(), userId: 'u');

      expect(result.outcome, PushOutcome.settled);
      expect(meds.get('m1')!['quantity'], 15);
      expect(await waiting(), ['taken']);
      final row = await med();
      expect([row['quantity'], row['sync_status']], [14, 'synced']);
      expect(row['sync_version'], 1);
    });

    test('a new medication that meets another copy on the server keeps its '
        'changes, in their place', () async {
      await createdAndRestocked();
      await change('taken', -1);
      // The same id reached the server from elsewhere between the read and
      // the insert (a restore on two devices), and a count is typed here
      // meanwhile.
      var held = false;
      meds.beforeCall = () async {
        if (held) return;
        held = true;
        final db = await AppDatabase.instance.database;
        await StockOutboxLocalDatasource.enqueue(
          db,
          StockOp(
            opId: 'count',
            medicationId: 'm1',
            setTo: 12,
            createdAt: DateTime.utc(2026, 3, 5, 11, 30),
          ),
        );
        await db.update('medications', {'quantity': 12});
        core.insertIfAbsent('medications', [
          {
            'id': 'm1',
            'user_id': 'u',
            'name': 'Moment',
            'quantity': 20,
            'write_id': 'other',
            'edited_at': '2026-03-05T09:00:00Z',
          },
        ]);
      };

      await medSync.pushRow(await med(), userId: 'u');

      expect(meds.get('m1')!['quantity'], 20);
      // Back in the order they were made: the count still comes last.
      expect(await waiting(), ['restock', 'taken', 'count']);
      // The server's 20 with the three changes on top.
      expect((await med())['quantity'], 12);
    });

    test('a medication removed from the server is created again with its '
        'quantity, and its waiting changes are not sent again', () async {
      meds.seed({'id': 'm1', 'user_id': 'u', 'name': 'Ibu', 'quantity': 10});
      await medSync.applyPulled(core.fetch('medications', 'm1')!);
      await change('taken', -1);
      final db = await AppDatabase.instance.database;
      await writeLocalChange(db, 'medications', 'm1', {
        'name': 'Ibuprofen',
        'sync_status': 'pending_update',
        'updated_at': '2026-03-05T11:30:00.000Z',
        'edited_at': '2026-03-05T11:30:00.000Z',
      }, at: DateTime.utc(2026, 3, 5, 11, 30));
      meds.hardDelete('m1');

      await medSync.pushRow(await med(), userId: 'u');

      expect(
        [meds.get('m1')!['name'], meds.get('m1')!['quantity']],
        ['Ibuprofen', 9],
      );
      expect(await waiting(), isEmpty);
      expect((await med())['quantity'], 9);
    });

    test('an edit never sends the quantity, even when it differs from the '
        'base', () async {
      meds.seed({'id': 'm1', 'user_id': 'u', 'name': 'Ibu', 'quantity': 10});
      await medSync.applyPulled(core.fetch('medications', 'm1')!);
      final db = await AppDatabase.instance.database;
      await writeLocalChange(db, 'medications', 'm1', {
        'name': 'Ibuprofen',
        'quantity': 4,
        'sync_status': 'pending_update',
        'updated_at': '2026-03-05T11:30:00.000Z',
        'edited_at': '2026-03-05T11:30:00.000Z',
      }, at: DateTime.utc(2026, 3, 5, 11, 30));
      core.applyStockChange(opId: 'other', medicationId: 'm1', delta: -3);

      await medSync.pushRow(await med(), userId: 'u');

      expect(meds.sent.where((s) => s.containsKey('quantity')), isEmpty);
      expect(
        [meds.get('m1')!['name'], meds.get('m1')!['quantity']],
        ['Ibuprofen', 7],
      );
      final times = FieldTimes.decode(meds.get('m1')!['field_edited_at']);
      expect(times.of('quantity'), isNull);
    });

    test('a forced push never patches the quantity', () async {
      meds.seed({'id': 'm1', 'user_id': 'u', 'name': 'Ibu', 'quantity': 10});
      await medSync.applyPulled(core.fetch('medications', 'm1')!);
      final db = await AppDatabase.instance.database;
      await db.update('medications', {'quantity': 4});

      await medSync.pushRow(await med(), userId: 'u', force: true);

      expect(meds.sent.single.containsKey('quantity'), isFalse);
      expect(meds.get('m1')!['quantity'], 10);
    });
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

    test('a row with nothing left to send does not bring back a dose '
        'another device dropped', () async {
      final since = core.horizon;
      core.patch('dose_logs', 'd1', {
        'deleted_at': '2026-03-01T06:00:00.000Z',
        'write_id': 'other-drop',
        'edited_at': automaticEditedAt.toIso8601String(),
      }, ifStatus: 'pending');
      // Pending, but a person's change was undone: it equals its base.
      await localChange({
        'edited_at': '2026-03-01T06:30:00.000Z',
        'field_edited_at':
            '{"status":{"at":"2026-03-01T06:30:00.000Z","auto":false}}',
      });
      expect((await pullDoses(since)).single.outcome, PullOutcome.deleted);
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

    test('a dropped slot here and a skip pulled from another device: the '
        'skip is stored', () async {
      final since = core.horizon;
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
        'edited_at': automaticEditedAt.toIso8601String(),
      }, where: "id = 'd1'");
      doses.editFromOtherDevice('d1', {
        'status': 'skipped',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      expect((await pullDoses(since)).single.outcome, PullOutcome.replaced);
      expect(
        [(await dose())['status'], (await dose())['sync_status']],
        ['skipped', 'synced'],
      );
    });

    group('a take pulled here, undone by a person here, then the slot '
        'dropped here (cycle review I-2)', () {
      final local = DoseLogLocalDatasource(now: () => now);

      Future<void> takenElsewhereUndoneHereThenDropped() async {
        final since = core.horizon;
        doses.editFromOtherDevice(
          'd1',
          {'status': 'taken', 'taken_time': '2026-03-01T07:05:00.000Z'},
          editedAt: DateTime.utc(2026, 3, 1, 7, 5),
          fieldTimes: {
            'status': {'at': '2026-03-01T07:05:00.000Z', 'auto': false},
            'taken_time': {'at': '2026-03-01T07:05:00.000Z', 'auto': false},
          },
        );
        await pullDoses(since);
        expect((await dose())['status'], 'taken');
        now = DateTime.utc(2026, 3, 1, 7, 10);
        await local.updateStatus(
          'd1',
          'pending',
          clearTakenTime: true,
          syncStatus: 'pending_update',
        );
        now = DateTime.utc(2026, 3, 1, 7, 12);
        expect(await local.dropPendingByPrescription('p1'), 1);
        expect(
          [(await dose())['sync_status'], (await dose())['delete_guard']],
          ['pending_delete', 'if_pending'],
        );
      }

      test('a pull of a later copy that did not touch the status keeps the '
          'drop; the push sends the undo, then the drop', () async {
        await takenElsewhereUndoneHereThenDropped();
        final since = core.horizon;
        doses.editFromOtherDevice('d1', {
          'notes': 'with food',
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 11));
        expect((await pullDoses(since)).single.outcome, PullOutcome.kept);
        expect((await dose())['sync_status'], 'pending_delete');

        final before = core.requests.length;
        await doseSync.pushRow(await dose(), userId: 'u');
        expect(core.requests.sublist(before), [
          'dose_logs:patch', // the drop: no longer pending there
          'dose_logs:fetch',
          'dose_logs:patch', // the undo, at the fetched version
          'dose_logs:patch', // the drop again
        ]);
        final server = doses.get('d1')!;
        expect(
          [server['status'], server['taken_time'], server['notes']],
          ['pending', null, 'with food'],
        );
        expect(server['deleted_at'], isNotNull);
        expect(server['edited_at'], startsWith('1970-01-01'));
        expect((server['field_edited_at'] as Map)['status'], {
          'at': '2026-03-01T07:10:00.000Z',
          'auto': false,
        });
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      });

      test('a take there after the undo wins: the take is stored', () async {
        await takenElsewhereUndoneHereThenDropped();
        final since = core.horizon;
        doses.editFromOtherDevice('d1', {
          'status': 'pending',
          'taken_time': null,
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 14));
        doses.editFromOtherDevice('d1', {
          'status': 'taken',
          'taken_time': '2026-03-01T07:15:00.000Z',
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 15));
        await doseSync.pushRow(await dose(), userId: 'u');
        final server = doses.get('d1')!;
        expect([server['status'], server['deleted_at']], ['taken', null]);
        final row = await dose();
        expect(
          [row['status'], row['sync_status'], row['delete_guard']],
          ['taken', 'synced', null],
        );
        expect((await pullDoses(since)).map((a) => a.outcome), [
          PullOutcome.kept,
        ]);
      });

      test('the drop sent while the server copy moves again fails and is '
          'tried again later', () async {
        await takenElsewhereUndoneHereThenDropped();
        final moving = _MovingTable(core, 'dose_logs');
        final raced = TableSync(
          table: 'dose_logs',
          remote: moving,
          newWriteId: () => 'd${ids++}',
          now: () => now,
        );
        await expectLater(
          raced.pushRow(await dose(), userId: 'u'),
          throwsStateError,
        );
        expect((await dose())['sync_status'], 'pending_delete');
        await doseSync.pushRow(await dose(), userId: 'u');
        final server = doses.get('d1')!;
        expect(
          [server['status'], server['deleted_at'] != null],
          ['pending', true],
        );
      });
    });

    test('a dropped slot whose create never got an answer, and that the '
        'server lacks: nothing is sent in its place', () async {
      final db = await AppDatabase.instance.database;
      core.rowsOf('dose_logs').remove('d1');
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
        'sync_write_id': 'lost',
      }, where: "id = 'd1'");
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(doses.insertBatches, isEmpty);
      expect(doses.get('d1'), isNull);
      expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
    });

    test('a dropped slot the server still holds pending, where the guarded '
        'delete matched nothing, fails and is tried again later', () async {
      final db = await AppDatabase.instance.database;
      final racing = _MissingPatchTable(core, 'dose_logs');
      final raced = TableSync(
        table: 'dose_logs',
        remote: racing,
        newWriteId: () => 'd${ids++}',
        now: () => now,
      );
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
      }, where: "id = 'd1'");
      await expectLater(
        raced.pushRow(await dose(), userId: 'u'),
        throwsStateError,
      );
      expect(
        [(await dose())['sync_status'], (await dose())['delete_guard']],
        ['pending_delete', 'if_pending'],
      );
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(doses.get('d1')!['deleted_at'], isNotNull);
      expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
    });

    group('deletes and the prescription above (review C-1)', () {
      Future<void> deletePrescriptionHere() async {
        final db = await AppDatabase.instance.database;
        await db.update('prescriptions', {
          'sync_status': 'pending_delete',
          'deleted_at': '2026-03-01T06:30:00.000Z',
        }, where: "id = 'p1'");
      }

      test('only doses come back: a prescription deleted with its '
          'treatment elsewhere stays deleted, whatever waits here', () async {
        final prescriptions = TableSync(
          table: 'prescriptions',
          remote: FakeSyncTable(core, 'prescriptions'),
          newWriteId: () => 'p${ids++}',
          now: () => now,
        );
        core.legacyUpsert('treatments', {
          'id': 't1',
          'name': 'Flu',
          'start_date': '2026-03-01',
        });
        core.legacyUpsert('prescriptions', {
          'id': 'p1',
          'treatment_id': 't1',
          'medication_id': 'm1',
          'dosage': '1',
          'start_time': '2026-03-01T08:00:00.000Z',
        });
        core.patch('treatments', 't1', {
          'deleted_at': '2026-03-01T06:00:00.000Z',
          'write_id': 'other',
          'edited_at': '2026-03-01T06:00:00.000Z',
        });
        final server = core.fetch('prescriptions', 'p1')!;
        expect(
          isAutomaticEdit(DateTime.parse(server['edited_at'] as String)),
          isTrue,
        );
        // A person's change to it waits here; the treatment is still live
        // here.
        final db = await AppDatabase.instance.database;
        await db.update('prescriptions', {
          'dosage': '2',
          'sync_status': 'pending_update',
          'edited_at': '2026-03-01T07:00:00.000Z',
        }, where: "id = 'p1'");
        final applied = await prescriptions.applyPulled(server);
        expect(applied.outcome, PullOutcome.deleted);
        expect(await db.query('prescriptions', where: "id = 'p1'"), isEmpty);
      });

      test('a forced push of a dose whose prescription is deleted on the '
          'server fails and keeps the dose here', () async {
        core.legacyUpsert('prescriptions', {
          'id': 'p1',
          'treatment_id': 't1',
          'medication_id': 'm1',
          'dosage': '1',
          'start_time': '2026-03-01T08:00:00.000Z',
          'deleted_at': '2026-03-01T06:00:00.000Z',
        });
        await takeHere(DateTime.utc(2026, 3, 1, 7, 5));
        await expectLater(
          doseSync.pushRow(await dose(), userId: 'u', force: true),
          throwsStateError,
        );
        expect(doses.get('d1')!['deleted_at'], isNotNull);
        expect(
          [(await dose())['status'], (await dose())['sync_status']],
          ['taken', 'pending_update'],
        );
      });

      test('a take here does not bring back a dropped dose whose '
          'prescription is deleted here', () async {
        final since = core.horizon;
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
        await deletePrescriptionHere();
        expect((await pullDoses(since)).single.outcome, PullOutcome.deleted);
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      });

      test('a live dose pulled for a prescription deleted here goes with '
          'it', () async {
        final since = core.horizon;
        doses.editFromOtherDevice('d1', {
          'status': 'taken',
          'taken_time': '2026-03-01T07:05:00.000Z',
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
        await deletePrescriptionHere();
        expect((await pullDoses(since)).single.outcome, PullOutcome.deleted);
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
        // A new one is not stored either.
        core.insertIfAbsent('dose_logs', [
          {
            'id': 'd9',
            'prescription_id': 'p1',
            'scheduled_time': '2026-03-02T07:00:00.000Z',
            'status': 'pending',
            'write_id': 'gen9',
            'edited_at': automaticEditedAt.toIso8601String(),
          },
        ]);
        expect(
          (await doseSync.applyPulled(doses.get('d9')!)).outcome,
          PullOutcome.kept,
        );
        expect(await db.query('dose_logs', where: "id = 'd9'"), isEmpty);
      });

      test('a live dose pulled for a prescription this device does not '
          'hold is reported, not stored, and nothing throws', () async {
        core.insertIfAbsent('dose_logs', [
          {
            'id': 'd9',
            'prescription_id': 'p-elsewhere',
            'scheduled_time': '2026-03-02T07:00:00.000Z',
            'status': 'pending',
            'write_id': 'gen9',
            'edited_at': automaticEditedAt.toIso8601String(),
          },
        ]);
        final applied = await doseSync.applyPulled(doses.get('d9')!);
        expect(applied.outcome, PullOutcome.orphaned);
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd9'"), isEmpty);
      });

      test('a dose whose prescription is deleted here is not sent, and '
          'goes', () async {
        await takeHere(DateTime.utc(2026, 3, 1, 7, 5));
        await deletePrescriptionHere();
        final sentBefore = doses.sent.length;
        final result = await doseSync.pushRow(await dose(), userId: 'u');
        expect(result.outcome, PushOutcome.settled);
        expect(doses.sent.length, sentBefore);
        expect(doses.get('d1')!['status'], 'pending');
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      });

      for (final kind in ['a generated dose', 'a take']) {
        test('$kind the server stores deleted, because the prescription is '
            'deleted there, is removed here at once', () async {
          // Another device deleted the prescription; this one has not
          // pulled it yet.
          core.legacyUpsert('prescriptions', {
            'id': 'p1',
            'deleted_at': '2026-03-01T06:30:00.000Z',
          });
          final db = await AppDatabase.instance.database;
          await db.insert('dose_logs', {
            'id': 'd8',
            'prescription_id': 'p1',
            'scheduled_time': '2026-03-02T07:00:00.000',
            'status': kind == 'a take' ? 'taken' : 'pending',
            'updated_at': '1970-01-01T00:00:00.000Z',
            'edited_at': kind == 'a take'
                ? '2026-03-01T07:05:00.000Z'
                : '1970-01-01T00:00:00.000Z',
            'sync_status': 'pending_create',
          });
          final row = (await db.query('dose_logs', where: "id = 'd8'")).single;
          final result = await doseSync.pushRow(row, userId: 'u');
          expect(result.outcome, PushOutcome.settled);
          expect(doses.get('d8')!['deleted_at'], isNotNull);
          expect(await db.query('dose_logs', where: "id = 'd8'"), isEmpty);
          // The same answer read later (a lost answer) removes it too.
          if (kind == 'a take') {
            await db.insert('dose_logs', {
              ...row,
              'sync_status': 'pending_update',
              'sync_write_id': doses.get('d8')!['write_id'],
            });
            final again = (await db.query(
              'dose_logs',
              where: "id = 'd8'",
            )).single;
            await doseSync.pushRow(again, userId: 'u');
            expect(await db.query('dose_logs', where: "id = 'd8'"), isEmpty);
          }
        });
      }
    });

    group('a slot dropped, then generated again (review I-1)', () {
      /// Another device dropped d1 at 06:00 (or a person deleted it).
      void dropElsewhere({bool person = false}) {
        core.patch('dose_logs', 'd1', {
          'deleted_at': '2026-03-01T06:00:00.000Z',
          'write_id': 'other-drop',
          'edited_at': person
              ? '2026-03-01T06:00:00.000Z'
              : automaticEditedAt.toIso8601String(),
        }, ifStatus: person ? null : 'pending');
      }

      /// The schedule here generates d1 at [at] (no time: an older row).
      Future<Map<String, Object?>> generateHere(DateTime? at) async {
        final db = await AppDatabase.instance.database;
        await db.delete('dose_logs', where: "id = 'd1'");
        await db.insert('dose_logs', {
          'id': 'd1',
          'prescription_id': 'p1',
          'scheduled_time': DateTime.utc(
            2026,
            3,
            1,
            7,
          ).toLocal().toIso8601String(),
          'status': 'pending',
          'created_at': at?.toLocal().toIso8601String(),
          'updated_at': '1970-01-01T00:00:00.000Z',
          'edited_at': '1970-01-01T00:00:00.000Z',
          'sync_status': 'pending_create',
        });
        return dose();
      }

      for (final at in [DateTime.utc(2026, 3, 1, 6, 30), null]) {
        test(
          'generated ${at == null ? 'at an unknown time' : 'after the '
                    'drop'}: it comes back, as the app\'s own change',
          () async {
            dropElsewhere();
            final before = doses.get('d1')!['updated_at'];
            final result = await doseSync.pushRow(
              await generateHere(at),
              userId: 'u',
            );
            expect(result.outcome, PushOutcome.settled);
            final server = doses.get('d1')!;
            expect(
              [server['deleted_at'], server['edited_at'], server['updated_at']],
              [null, '1970-01-01T00:00:00.000Z', before],
            );
            final row = await dose();
            expect(
              [row['sync_status'], row['deleted_at'], row['sync_write_id']],
              ['synced', null, null],
            );
            // Nothing left to send.
            final version = server['row_version'];
            await doseSync.pushRow(await dose(), userId: 'u');
            expect(doses.get('d1')!['row_version'], version);
          },
        );
      }

      test('generated before the drop: it stays dropped', () async {
        dropElsewhere();
        await doseSync.pushRow(
          await generateHere(DateTime.utc(2026, 3, 1, 5, 30)),
          userId: 'u',
        );
        expect(doses.get('d1')!['deleted_at'], isNotNull);
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      });

      test('a dose a person deleted is not brought back', () async {
        dropElsewhere(person: true);
        await doseSync.pushRow(
          await generateHere(DateTime.utc(2026, 3, 1, 6, 30)),
          userId: 'u',
        );
        expect(doses.get('d1')!['deleted_at'], isNotNull);
        final db = await AppDatabase.instance.database;
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      });

      test('the drop pulled while the generated slot waits here: the slot '
          'stays and goes out next', () async {
        final since = core.horizon;
        dropElsewhere();
        await generateHere(DateTime.utc(2026, 3, 1, 6, 30));
        final applied = (await pullDoses(since)).single;
        expect(applied.outcome, PullOutcome.merged);
        expect(
          [(await dose())['deleted_at'], (await dose())['sync_status']],
          [null, 'pending_update'],
        );
        await doseSync.pushRow(await dose(), userId: 'u');
        expect(doses.get('d1')!['deleted_at'], isNull);
        expect((await dose())['sync_status'], 'synced');
      });
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

    test('a push of the app\'s change and a person\'s together: each column '
        'keeps its own kind, and updated_at moves', () async {
      final db = await AppDatabase.instance.database;
      await writeLocalChange(db, 'dose_logs', 'd1', {
        'status': 'missed',
        'sync_status': 'pending_update',
      }, at: automaticEditedAt);
      await writeLocalChange(db, 'dose_logs', 'd1', {
        'notes': 'felt sick',
        'edited_at': '2026-03-01T09:00:00.000Z',
      }, at: DateTime.utc(2026, 3, 1, 9));
      final before = doses.get('d1')!['updated_at'];
      await doseSync.pushRow(await dose(), userId: 'u');
      final server = doses.get('d1')!;
      final times = RemoteMeta.fromJson(server).fieldTimes;
      expect(times.of('status'), FieldTime.automaticChange);
      expect(times.of('notes'), FieldTime(DateTime.utc(2026, 3, 1, 9)));
      expect(server['edited_at'], '2026-03-01T09:00:00.000Z');
      expect(server['updated_at'], isNot(before));
    });

    test('a push of the app\'s change alone is sent as automatic, whatever '
        'time the row itself carries', () async {
      final db = await AppDatabase.instance.database;
      // A person changed this dose once (its map records that), then the
      // app marked it missed: the sweep leaves the row's edited_at alone.
      await writeLocalChange(db, 'dose_logs', 'd1', {
        'notes': 'n',
        'edited_at': '2026-03-01T06:00:00.000Z',
        'sync_status': 'pending_update',
      }, at: DateTime.utc(2026, 3, 1, 6));
      await doseSync.pushRow(await dose(), userId: 'u');
      expect((await dose())['sync_status'], 'synced');
      await writeLocalChange(db, 'dose_logs', 'd1', {
        'status': 'missed',
        'sync_status': 'pending_update',
      }, at: automaticEditedAt);
      final before = doses.get('d1')!['updated_at'];
      await doseSync.pushRow(await dose(), userId: 'u');
      final server = doses.get('d1')!;
      expect(server['edited_at'], '1970-01-01T00:00:00.000Z');
      expect(server['updated_at'], before);
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

  group('edit times per column', () {
    test('a push sends the times of the columns it writes; the server keeps '
        'the others', () async {
      await warmUp();
      remote.editFromOtherDevice('t1', {
        'doctor': 'Dr. Bianchi',
      }, editedAt: DateTime.utc(2026, 3, 5, 11));
      final before = serverTimes('t1');
      await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
      await edit('t1', {
        'sick_leave_ref': 'CERT',
      }, DateTime.utc(2026, 3, 5, 10, 30));
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      final after = serverTimes('t1');
      expect(after.of('notes'), FieldTime(DateTime.utc(2026, 3, 5, 10)));
      expect(
        after.of('sick_leave_ref'),
        FieldTime(DateTime.utc(2026, 3, 5, 10, 30)),
      );
      expect(after.of('doctor'), FieldTime(DateTime.utc(2026, 3, 5, 11)));
      expect(after.of('name'), before.of('name'));
      expect(
        remote.get('t1')!['edited_at'],
        '2026-03-05T10:30:00.000Z',
        reason: 'the row carries its latest change',
      );
      // Settled: the local row holds the server's map.
      final row = await local('t1');
      expect(row['sync_status'], 'synced');
      expect(localFieldTimes(row).entries, after.entries);
    });

    test('a push of a column whose time is unknown, with the app\'s own '
        'changes, goes out with the row time, not as automatic', () async {
      await warmUp();
      final db = await AppDatabase.instance.database;
      // The map knows the app's own change to notes, and nothing of the
      // doctor (a merge took it from here with no time).
      await db.update('treatments', {
        'notes': 'auto',
        'doctor': 'Dr. Bianchi',
        'sync_status': 'pending_update',
        'edited_at': '2026-03-05T09:00:00.000Z',
        'field_edited_at':
            '{"notes":{"at":"1970-01-01T00:00:00.000Z","auto":true}}',
      }, where: "id = 't1'");
      await sync.pushRow(await local('t1'), userId: 'u');
      final server = remote.get('t1')!;
      expect(server['edited_at'], '2026-03-05T09:00:00.000Z');
      expect(
        serverTimes('t1').of('doctor'),
        FieldTime(DateTime.utc(2026, 3, 5, 9)),
      );
      expect(serverTimes('t1').of('notes')!.automatic, isTrue);
    });

    test('a settled row holds the server\'s times, capped when they '
        'arrived, not the ones this device sent', () async {
      await warmUp();
      // This device's clock runs a day ahead.
      final ahead = now.add(const Duration(days: 1));
      await edit('t1', {'notes': 'from the future'}, ahead);
      expect(localFieldTimes(await local('t1')).of('notes'), FieldTime(ahead));
      await sync.pushRow(await local('t1'), userId: 'u');
      final row = await local('t1');
      expect(row['sync_status'], 'synced');
      expect(localFieldTimes(row).of('notes'), FieldTime(now));
      expect(localFieldTimes(row).entries, serverTimes('t1').entries);
    });

    test('a pulled row stores the server\'s map; a merged one the server\'s '
        'with this device\'s for what it kept', () async {
      await warmUp();
      await edit('t1', {'notes': 'mine'}, DateTime.utc(2026, 3, 5, 10));
      final since = core.horizon;
      remote.editFromOtherDevice('t1', {
        'doctor': 'Dr. Bianchi',
      }, editedAt: DateTime.utc(2026, 3, 5, 9));
      final applied = await sync.applyPulled(
        core.page('treatments', horizon: core.horizon, afterXid: since).single,
      );
      expect(applied.outcome, PullOutcome.merged);
      final row = await local('t1');
      expect(row['sync_status'], 'pending_update');
      final times = localFieldTimes(row);
      expect(times.of('notes'), FieldTime(DateTime.utc(2026, 3, 5, 10)));
      expect(times.of('doctor'), FieldTime(DateTime.utc(2026, 3, 5, 9)));
      expect(times.of('name'), serverTimes('t1').of('name'));

      // Another device's newer change to the same column: the pull stores
      // the server copy and its map, once this row is in step.
      await sync.pushRow(row, userId: 'u');
      final since2 = core.horizon;
      remote.editFromOtherDevice('t1', {
        'notes': 'theirs',
      }, editedAt: DateTime.utc(2026, 3, 5, 11));
      await sync.applyPulled(
        core.page('treatments', horizon: core.horizon, afterXid: since2).single,
      );
      final synced = await local('t1');
      expect(synced['sync_status'], 'synced');
      expect(localFieldTimes(synced).entries, serverTimes('t1').entries);
      expect(
        localFieldTimes(synced).of('notes'),
        FieldTime(DateTime.utc(2026, 3, 5, 11)),
      );
    });

    test('a create sends the map it has; with none the server reads the row '
        'time', () async {
      final db = await AppDatabase.instance.database;
      await db.insert('treatments', {
        'id': 't7',
        'name': 'Cold',
        'start_date': '2026-03-05',
        'is_active': 1,
        'updated_at': '2026-03-05T09:00:00.000Z',
        'edited_at': '2026-03-05T09:00:00.000Z',
        'sync_status': 'pending_create',
      });
      await edit('t7', {'notes': 'n'}, DateTime.utc(2026, 3, 5, 9, 30));
      await db.update('treatments', {
        'sync_status': 'pending_create',
      }, where: "id = 't7'");
      await sync.pushRow(await local('t7'), userId: 'u');
      expect(
        serverTimes('t7').of('notes'),
        FieldTime(DateTime.utc(2026, 3, 5, 9, 30)),
      );
      expect(
        serverTimes('t7').of('name'),
        FieldTime(DateTime.utc(2026, 3, 5, 9)),
      );

      await db.insert('treatments', {
        'id': 't8',
        'name': 'Flu',
        'start_date': '2026-03-05',
        'is_active': 1,
        'updated_at': '2026-03-05T09:00:00.000Z',
        'edited_at': '2026-03-05T09:00:00.000Z',
        'sync_status': 'pending_create',
      });
      await sync.pushRow(await local('t8'), userId: 'u');
      expect(remote.get('t8')!['field_edited_at'], isEmpty);
      expect(
        RemoteMeta.fromJson(remote.get('t8')!).fieldTimes.of('name'),
        FieldTime(DateTime.utc(2026, 3, 5, 9)),
      );
    });

    test('a row from before the migration against a change still waiting '
        'from 0.3.0: the newer server row wins, as under 0.3.0', () async {
      // Another device changed the doctor at 10:00 under 0.3.0; the server
      // row has no edit times at all.
      remote.seed({
        'id': 't1',
        'user_id': 'u',
        'name': 'Sinusitis',
        'start_date': '2026-03-02',
        'is_active': true,
        'doctor': 'Dr. Bianchi',
        'notes': null,
      }, updatedAt: DateTime.utc(2026, 3, 5, 10));
      remote.get('t1')!
        ..['edited_at'] = null
        ..['field_edited_at'] = <String, dynamic>{};
      // This device, upgraded from 0.3.0: its 09:00 note never went out,
      // and it never pulled the doctor. No base, no map.
      final db = await AppDatabase.instance.database;
      await db.insert('treatments', {
        'id': 't1',
        'user_id': 'u',
        'name': 'Sinusitis',
        'start_date': '2026-03-02',
        'is_active': 1,
        'doctor': 'Dr. Rossi',
        'notes': 'mine',
        'updated_at': '2026-03-05T09:00:00.000Z',
        'edited_at': '2026-03-05T09:00:00.000Z',
        'sync_status': 'pending_update',
      });
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      final server = remote.get('t1')!;
      expect([server['doctor'], server['notes']], ['Dr. Bianchi', null]);
      expect(
        result.conflicts.every((c) => !c.keptLocal),
        isTrue,
        reason: '${result.conflicts}',
      );
      expect(result.conflicts, hasLength(2));
    });
  });

  test('writeTime: the latest person\'s change; 1970 when all are the '
      'app\'s own; nothing when there is none', () {
    final nine = FieldTime(DateTime.utc(2026, 3, 5, 9));
    final ten = FieldTime(DateTime.utc(2026, 3, 5, 10));
    expect(writeTime([nine, FieldTime.automaticChange, ten]), ten.at);
    expect(writeTime([ten, nine]), ten.at);
    expect(writeTime([FieldTime.automaticChange]), automaticEditedAt);
    expect(writeTime(const []), isNull);
  });

  test('isAutomaticEdit', () {
    expect(isAutomaticEdit(automaticEditedAt), isTrue);
    expect(isAutomaticEdit(DateTime.utc(2026)), isFalse);
    expect(syncedTables, hasLength(7));
  });
}

/// A dose table whose guarded patch matches nothing once, as when the row
/// changed and changed back between the patch and the fetch.
class _MissingPatchTable extends FakeSyncTable {
  _MissingPatchTable(super.core, super.table);

  var _missed = false;

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    if (ifStatus != null && !_missed) {
      _missed = true;
      return null;
    }
    return super.patch(
      id,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
  }
}

/// Another device writes to the row just before this device's first
/// versioned patch reaches the server.
class _MovingTable extends FakeSyncTable {
  _MovingTable(super.core, super.table);

  var _moved = false;

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    if (ifVersion != null && !_moved) {
      _moved = true;
      editFromOtherDevice(id, {
        'notes': 'moved',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 13));
    }
    return super.patch(
      id,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
  }
}
