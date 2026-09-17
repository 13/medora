/// Two devices with history, one server: which change wins when both
/// devices change the same thing (sync v2, controller decision 1).
///
/// - The same field changed on two devices: the later device edit time
///   wins, capped at the time the server received the change.
/// - A person's change always beats a change the app made on its own.
///
/// Each device keeps its own database file and its own clock. Run this file
/// under `TZ=Europe/Rome` too: the daylight-saving cases only tell a
/// wall-clock reading from an instant in a zone that has the change.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/local_write.dart';
import '../../helpers/test_database.dart';

/// One phone: its database file, its clock (the server's plus [skew]) and
/// its pull keys.
class _Device {
  _Device(this.name, this.path, this.core);

  final String name;
  final String path;
  final FakeServerCore core;
  Duration skew = Duration.zero;
  final Map<String, PullKey> _keys = {};
  var _ids = 0;

  /// The same-field changes this device's syncs dropped or kept.
  final List<MergeConflict> conflicts = [];

  DateTime now() => core.clock().add(skew);

  Future<Database> open() async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = path;
    return AppDatabase.instance.database;
  }

  TableSync _engine(String table) => TableSync(
    table: table,
    remote: FakeSyncTable(core, table),
    newWriteId: () => '$name-${_ids++}',
    now: now,
  );

  /// What each pulled row did, in order, as `table/id outcome`.
  final List<String> pulled = [];

  /// One cycle: push every pending row in foreign-key order, then pull
  /// every table to the horizon.
  Future<void> sync() async {
    await push();
    await pull();
  }

  /// Pushes every pending row in foreign-key order, each row as the table
  /// holds it when its turn comes (a parent's delete may have removed it).
  Future<void> push() async {
    final db = await open();
    for (final table in syncedTables) {
      final engine = _engine(table);
      for (final listed in await db.query(
        table,
        columns: ['id'],
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.synced],
      )) {
        final rows = await db.query(
          table,
          where: 'id = ?',
          whereArgs: [listed['id']],
        );
        if (rows.isEmpty) continue;
        conflicts.addAll(
          (await engine.pushRow(rows.single, userId: 'u')).conflicts,
        );
      }
    }
  }

  /// Pulls every table to the horizon.
  Future<void> pull() async {
    await open();
    final horizon = core.horizon;
    for (final table in syncedTables) {
      final engine = _engine(table);
      final remote = FakeSyncTable(core, table);
      while (true) {
        final rows = await remote.page(after: _keys[table], horizon: horizon);
        for (final row in rows) {
          final applied = await engine.applyPulled(row);
          pulled.add('$table/${row['id']} ${applied.outcome.name}');
          conflicts.addAll(applied.conflicts);
        }
        final next = afterPullPage(rows, horizon: horizon);
        _keys[table] = next.key;
        if (next.done) break;
      }
    }
  }

  Future<Map<String, Object?>?> row(String table, String id) async {
    final rows = await (await open()).query(
      table,
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> insert(String table, Map<String, Object?> values) async =>
      (await open()).insert(table, {
        'sync_status': SyncStatus.pendingCreate,
        ...values,
      });

  /// A person's change, made now on this device's clock.
  Future<void> edit(String table, String id, Map<String, Object?> values) =>
      _write(table, id, {
        ...values,
        'updated_at': now().toUtc().toIso8601String(),
        'edited_at': now().toUtc().toIso8601String(),
      }, at: now().toLocal());

  /// A change the app made on its own.
  Future<void> automatic(
    String table,
    String id,
    Map<String, Object?> values, {
    String status = SyncStatus.pendingUpdate,
  }) => _write(
    table,
    id,
    {...values, 'edited_at': automaticEditedAt.toIso8601String()},
    at: automaticEditedAt,
    status: status,
  );

  /// Writes [values] as the app's write paths do: the columns they change
  /// are stamped [at].
  Future<void> _write(
    String table,
    String id,
    Map<String, Object?> values, {
    required DateTime at,
    String status = SyncStatus.pendingUpdate,
  }) async {
    final db = await open();
    final current = (await db.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    await writeLocalChange(db, table, id, {
      ...values,
      'sync_status': current['sync_status'] == SyncStatus.pendingCreate
          ? SyncStatus.pendingCreate
          : status,
    }, at: at);
  }
}

void main() {
  late Directory dir;
  late DateTime serverNow;
  late FakeServerCore core;
  late _Device a;
  late _Device b;

  /// Wall-clock text as a device in the test's zone writes it.
  String wallClock(DateTime instant) => instant.toLocal().toIso8601String();

  /// A generated dose, as the schedule writes it on either device.
  Map<String, Object?> generated(String id, DateTime at) => {
    'id': id,
    'prescription_id': 'p1',
    'scheduled_time': wallClock(at),
    'status': 'pending',
    'updated_at': automaticEditedAt.toIso8601String(),
    'edited_at': automaticEditedAt.toIso8601String(),
  };

  setUp(() async {
    await setUpTestDatabase();
    dir = Directory.systemTemp.createTempSync('medora_edit_time_');
    serverNow = DateTime.utc(2026, 3, 2, 9);
    core = FakeServerCore(() => serverNow);
    a = _Device('a', p.join(dir.path, 'a.db'), core);
    b = _Device('b', p.join(dir.path, 'b.db'), core);

    // Three days ago, A set up the illness and its schedule.
    final created = serverNow.toIso8601String();
    await a.insert('medications', {
      'id': 'm1',
      'name': 'Amoxicillin',
      'quantity': 12,
      'updated_at': created,
      'edited_at': created,
    });
    await a.insert('treatments', {
      'id': 't1',
      'name': 'Sinusitis',
      'start_date': '2026-03-02',
      'is_active': 1,
      'sick_leave_from': '2026-03-02',
      'doctor': 'Dr. Rossi',
      'updated_at': created,
      'edited_at': created,
    });
    await a.insert('prescriptions', {
      'id': 'p1',
      'treatment_id': 't1',
      'medication_id': 'm1',
      'dosage': '1 tablet',
      'start_time': '2026-03-02T08:00:00.000',
      'schedule_type': 'fixed_times',
      'schedule_times': '["08:00","20:00"]',
      'updated_at': created,
      'edited_at': created,
    });
    await a.insert('dose_logs', generated('d0', DateTime.utc(2026, 3, 2, 19)));
    await a.insert('dose_logs', generated('d1', DateTime.utc(2026, 3, 5, 7)));
    await a.sync();
    serverNow = DateTime.utc(2026, 3, 2, 9, 5);
    await b.sync();

    // The next evening B added a note and took the evening dose.
    serverNow = DateTime.utc(2026, 3, 3, 18);
    await b.edit('treatments', 't1', {'notes': 'after food'});
    serverNow = DateTime.utc(2026, 3, 3, 19, 5);
    await b.edit('dose_logs', 'd0', {
      'status': 'taken',
      'taken_time': b.now().toIso8601String(),
    });
    await b.sync();
    serverNow = DateTime.utc(2026, 3, 3, 20);
    await a.sync();
    a.conflicts.clear();
    b.conflicts.clear();
  });

  tearDown(() async {
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  Future<List<Object?>> both(String table, String id, String column) async => [
    (await a.row(table, id))?[column],
    (await b.row(table, id))?[column],
    core.rowsOf(table)[id]?[column],
  ];

  Future<void> syncAll(List<_Device> order) async {
    for (final device in [...order, ...order]) {
      await device.sync();
    }
  }

  test('the history is in place on both devices', () async {
    expect(await both('treatments', 't1', 'notes'), [
      'after food',
      'after food',
      'after food',
    ]);
    expect(await both('dose_logs', 'd0', 'status'), [
      'taken',
      'taken',
      'taken',
    ]);
    expect(core.rowsOf('treatments')['t1']!['row_version'], 2);
    expect((await a.row('treatments', 't1'))!['sync_version'], 2);
    expect((await b.row('dose_logs', 'd1'))!['sync_status'], 'synced');
  });

  group('the same field on both devices', () {
    for (final order in ['A syncs last', 'B syncs last']) {
      test('the later edit wins: $order', () async {
        serverNow = DateTime.utc(2026, 3, 5, 10, 5);
        await a.edit('treatments', 't1', {'sick_leave_ref': 'CERT-A'});
        serverNow = DateTime.utc(2026, 3, 5, 10, 7);
        await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B'});
        serverNow = DateTime.utc(2026, 3, 5, 11);
        await syncAll(order == 'A syncs last' ? [b, a] : [a, b]);
        expect(await both('treatments', 't1', 'sick_leave_ref'), [
          'CERT-B',
          'CERT-B',
          'CERT-B',
        ]);
        final last = order == 'A syncs last' ? a : b;
        expect(last.conflicts.single.keptLocal, last == b);
      });
    }

    test('a clock running ahead is capped when the change arrives, so a '
        'later edit elsewhere still wins', () async {
      a.skew = const Duration(days: 1);
      serverNow = DateTime.utc(2026, 3, 5, 10);
      await a.edit('treatments', 't1', {'sick_leave_ref': 'CERT-A'});
      serverNow = DateTime.utc(2026, 3, 5, 10, 1);
      await a.sync();
      expect(
        core.rowsOf('treatments')['t1']!['edited_at'],
        '2026-03-05T10:01:00.000Z',
      );
      serverNow = DateTime.utc(2026, 3, 5, 10, 30);
      await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B'});
      serverNow = DateTime.utc(2026, 3, 5, 11);
      await syncAll([b, a]);
      expect(await both('treatments', 't1', 'sick_leave_ref'), [
        'CERT-B',
        'CERT-B',
        'CERT-B',
      ]);
    });

    test(
      'a clock running ahead wins only up to when its change arrives',
      () async {
        a.skew = const Duration(days: 1);
        serverNow = DateTime.utc(2026, 3, 5, 11, 30);
        await a.edit('treatments', 't1', {'sick_leave_ref': 'CERT-A'});
        serverNow = DateTime.utc(2026, 3, 5, 11, 40);
        await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B'});
        serverNow = DateTime.utc(2026, 3, 5, 11, 41);
        await b.sync();
        // A's change arrives at 12:00, after B's 11:40: A's value is kept.
        serverNow = DateTime.utc(2026, 3, 5, 12);
        await syncAll([a, b]);
        expect(await both('treatments', 't1', 'sick_leave_ref'), [
          'CERT-A',
          'CERT-A',
          'CERT-A',
        ]);
        expect(
          core.rowsOf('treatments')['t1']!['edited_at'],
          '2026-03-05T12:00:00.000Z',
        );
        // An edit B makes after that arrival wins, although A's clock showed
        // a later time for its own edit.
        serverNow = DateTime.utc(2026, 3, 5, 12, 10);
        await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B2'});
        serverNow = DateTime.utc(2026, 3, 5, 12, 11);
        await syncAll([b, a]);
        expect(await both('treatments', 't1', 'sick_leave_ref'), [
          'CERT-B2',
          'CERT-B2',
          'CERT-B2',
        ]);
      },
    );

    test('a clock running behind makes its edit count as earlier: the '
        'device clock is trusted', () async {
      a.skew = const Duration(hours: -2);
      serverNow = DateTime.utc(2026, 3, 5, 10);
      await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B'});
      serverNow = DateTime.utc(2026, 3, 5, 10, 1);
      await b.sync();
      // Really 10:30, but A's clock says 08:30.
      serverNow = DateTime.utc(2026, 3, 5, 10, 30);
      await a.edit('treatments', 't1', {'sick_leave_ref': 'CERT-A'});
      serverNow = DateTime.utc(2026, 3, 5, 10, 31);
      await syncAll([a, b]);
      expect(await both('treatments', 't1', 'sick_leave_ref'), [
        'CERT-B',
        'CERT-B',
        'CERT-B',
      ]);
      expect(a.conflicts.single.keptLocal, isFalse);
    });

    group('across a daylight-saving change', () {
      for (final (season, before, after) in [
        // Rome: 01:50 CET, then 03:10 CEST.
        (
          'spring',
          DateTime.utc(2026, 3, 29, 0, 50),
          DateTime.utc(2026, 3, 29, 1, 10),
        ),
        // Rome: 02:40 CEST, then 02:10 CET, an hour later.
        (
          'autumn',
          DateTime.utc(2026, 10, 25, 0, 40),
          DateTime.utc(2026, 10, 25, 1, 10),
        ),
      ]) {
        test(
          '$season: the later instant wins, whatever the clock read',
          () async {
            serverNow = before;
            await a.edit('treatments', 't1', {'sick_leave_ref': 'CERT-A'});
            serverNow = after;
            await b.edit('treatments', 't1', {'sick_leave_ref': 'CERT-B'});
            serverNow = after.add(const Duration(minutes: 30));
            await syncAll([b, a]);
            expect(await both('treatments', 't1', 'sick_leave_ref'), [
              'CERT-B',
              'CERT-B',
              'CERT-B',
            ]);
          },
        );

        test('$season: a row restored from a 0.3.0 backup goes by its '
            'wall-clock stamp, read as an instant', () async {
          // B restores a backup whose last change was made at [before]:
          // no base, no edit time, `updated_at` in local wall-clock time.
          final db = await b.open();
          await db.update('treatments', {
            'notes': 'restored note',
            'updated_at': wallClock(before),
            'sync_status': SyncStatus.pendingUpdate,
            'edited_at': null,
            'field_edited_at': null,
            ...clearedSyncMeta,
          }, where: "id = 't1'");
          serverNow = after;
          await a.edit('treatments', 't1', {'notes': 'note from A'});
          await a.sync();
          serverNow = after.add(const Duration(minutes: 30));
          await syncAll([b, a]);
          expect(await both('treatments', 't1', 'notes'), [
            'note from A',
            'note from A',
            'note from A',
          ]);
          expect(b.conflicts.single.keptLocal, isFalse);
        });
      }
    });
  });

  group('an edit back to the old value (review Minor 1, P3)', () {
    for (final order in ['A syncs first', 'B syncs first']) {
      test('is the latest edit, and wins: $order', () async {
        serverNow = DateTime.utc(2026, 3, 5, 9);
        await a.edit('treatments', 't1', {'notes': 'Y'});
        serverNow = DateTime.utc(2026, 3, 5, 9, 2);
        await b.edit('treatments', 't1', {'notes': 'Z'});
        await b.sync();
        serverNow = DateTime.utc(2026, 3, 5, 9, 5);
        await a.edit('treatments', 't1', {'notes': 'after food'});
        serverNow = DateTime.utc(2026, 3, 5, 10);
        await syncAll(order == 'A syncs first' ? [a, b] : [b, a]);
        expect(await both('treatments', 't1', 'notes'), [
          'after food',
          'after food',
          'after food',
        ]);
        for (final d in [a, b]) {
          expect((await d.row('treatments', 't1'))!['sync_status'], 'synced');
        }
      });
    }

    test(
      'an edit back made before the other device\'s change loses to it',
      () async {
        serverNow = DateTime.utc(2026, 3, 5, 9);
        await a.edit('treatments', 't1', {'notes': 'Y'});
        serverNow = DateTime.utc(2026, 3, 5, 9, 1);
        await a.edit('treatments', 't1', {'notes': 'after food'});
        serverNow = DateTime.utc(2026, 3, 5, 9, 2);
        await b.edit('treatments', 't1', {'notes': 'Z'});
        await b.sync();
        serverNow = DateTime.utc(2026, 3, 5, 10);
        await syncAll([a, b]);
        expect(await both('treatments', 't1', 'notes'), ['Z', 'Z', 'Z']);
      },
    );

    test('a take undone after a take on the other device: the later action '
        'wins', () async {
      serverNow = DateTime.utc(2026, 3, 5, 7);
      await a.edit('dose_logs', 'd1', {
        'status': 'taken',
        'taken_time': a.now().toIso8601String(),
      });
      serverNow = DateTime.utc(2026, 3, 5, 7, 5);
      await b.edit('dose_logs', 'd1', {
        'status': 'taken',
        'taken_time': b.now().toIso8601String(),
      });
      await b.sync();
      serverNow = DateTime.utc(2026, 3, 5, 7, 10);
      await a.edit('dose_logs', 'd1', {
        'status': 'pending',
        'taken_time': null,
      });
      serverNow = DateTime.utc(2026, 3, 5, 8);
      await syncAll([a, b]);
      expect(await both('dose_logs', 'd1', 'status'), [
        'pending',
        'pending',
        'pending',
      ]);
    });

    test('a device whose edit landed but whose answer was lost, with a '
        'clock ahead, does not later undo a newer change elsewhere', () async {
      a.skew = const Duration(hours: 2);
      serverNow = DateTime.utc(2026, 3, 5, 9);
      await a.edit('treatments', 't1', {'notes': 'Y'});
      // A's push lands, but its answer is lost: the row backs off.
      final db = await a.open();
      final engine = TableSync(
        table: 'treatments',
        remote: _LosingTable(core, 'treatments'),
        newWriteId: () => 'a-lost',
        now: a.now,
      );
      await expectLater(
        engine.pushRow(
          (await db.query('treatments', where: "id = 't1'")).single,
          userId: 'u',
        ),
        throwsA(anything),
      );
      expect(core.rowsOf('treatments')['t1']!['notes'], 'Y');
      // A changes the doctor, and pulls while that row waits: the pull
      // finds A's own write.
      serverNow = DateTime.utc(2026, 3, 5, 9, 1);
      await a.edit('treatments', 't1', {'doctor': 'Dr. B'});
      await a.pull();
      expect(
        (await a.row('treatments', 't1'))!['sync_status'],
        SyncStatus.pendingUpdate,
      );
      // B changes the notes after A's arrived.
      serverNow = DateTime.utc(2026, 3, 5, 9, 30);
      await b.sync();
      await b.edit('treatments', 't1', {'notes': 'Z'});
      await b.sync();
      serverNow = DateTime.utc(2026, 3, 5, 10);
      await syncAll([a, b]);
      expect(await both('treatments', 't1', 'notes'), ['Z', 'Z', 'Z']);
      expect(await both('treatments', 't1', 'doctor'), [
        'Dr. B',
        'Dr. B',
        'Dr. B',
      ]);
    });
  });

  group('a person\'s change beats the app\'s own', () {
    Future<void> takeOnB(DateTime at, {String id = 'd1'}) async {
      serverNow = at;
      await b.edit('dose_logs', id, {
        'status': 'taken',
        'taken_time': b.now().toIso8601String(),
      });
    }

    for (final order in ['A syncs first', 'B syncs first']) {
      test('automatic missed on A, taken later on B: $order', () async {
        serverNow = DateTime.utc(2026, 3, 5, 10);
        await a.automatic('dose_logs', 'd1', {'status': 'missed'});
        await takeOnB(DateTime.utc(2026, 3, 5, 11));
        serverNow = DateTime.utc(2026, 3, 5, 12);
        await syncAll(order == 'A syncs first' ? [a, b] : [b, a]);
        expect(await both('dose_logs', 'd1', 'status'), [
          'taken',
          'taken',
          'taken',
        ]);
        expect(
          (await a.row('dose_logs', 'd1'))!['sync_status'],
          SyncStatus.synced,
        );
      });
    }

    test('a take made offline before the automatic missed reached the '
        'server still wins', () async {
      await takeOnB(DateTime.utc(2026, 3, 5, 7, 5));
      serverNow = DateTime.utc(2026, 3, 5, 10);
      await a.automatic('dose_logs', 'd1', {'status': 'missed'});
      await a.sync();
      expect(core.rowsOf('dose_logs')['d1']!['status'], 'missed');
      serverNow = DateTime.utc(2026, 3, 5, 18);
      await syncAll([b, a]);
      expect(await both('dose_logs', 'd1', 'status'), [
        'taken',
        'taken',
        'taken',
      ]);
      expect(b.conflicts.single.keptLocal, isTrue);
    });

    test('a corrected dose time on A and a take on B are both kept', () async {
      final corrected = DateTime.utc(2026, 3, 5, 6);
      serverNow = DateTime.utc(2026, 3, 5, 5);
      await a.automatic('dose_logs', 'd1', {
        'scheduled_time': wallClock(corrected),
      });
      await takeOnB(DateTime.utc(2026, 3, 5, 6, 5));
      serverNow = DateTime.utc(2026, 3, 5, 7);
      await syncAll([b, a]);
      expect(await both('dose_logs', 'd1', 'status'), [
        'taken',
        'taken',
        'taken',
      ]);
      final times = await both('dose_logs', 'd1', 'scheduled_time');
      for (final t in times) {
        expect(
          DateTime.parse(t! as String).isAtSameMomentAs(corrected),
          isTrue,
        );
      }
    });

    for (final order in ['A syncs first', 'B syncs first']) {
      test('a slot dropped on A and taken on B stays, taken: $order', () async {
        serverNow = DateTime.utc(2026, 3, 5, 6);
        await a.automatic('dose_logs', 'd1', {
          'delete_guard': 'if_pending',
        }, status: SyncStatus.pendingDelete);
        await takeOnB(DateTime.utc(2026, 3, 5, 7, 5));
        serverNow = DateTime.utc(2026, 3, 5, 8);
        await syncAll(order == 'A syncs first' ? [a, b] : [b, a]);
        expect(await both('dose_logs', 'd1', 'status'), [
          'taken',
          'taken',
          'taken',
        ]);
        expect(core.rowsOf('dose_logs')['d1']!['deleted_at'], isNull);
        expect(
          (await a.row('dose_logs', 'd1'))!['sync_status'],
          SyncStatus.synced,
        );
      });
    }

    for (final order in ['A syncs first', 'B syncs first']) {
      test(
        'a dose generated on both and taken on B is taken: $order',
        () async {
          final slot = DateTime.utc(2026, 3, 6, 7);
          serverNow = DateTime.utc(2026, 3, 6, 6);
          await a.insert('dose_logs', generated('d2', slot));
          await b.insert('dose_logs', generated('d2', slot));
          await takeOnB(DateTime.utc(2026, 3, 6, 7, 5), id: 'd2');
          serverNow = DateTime.utc(2026, 3, 6, 8);
          await syncAll(order == 'A syncs first' ? [a, b] : [b, a]);
          expect(await both('dose_logs', 'd2', 'status'), [
            'taken',
            'taken',
            'taken',
          ]);
          for (final device in [a, b]) {
            expect(
              (await device.row('dose_logs', 'd2'))!['sync_status'],
              SyncStatus.synced,
            );
          }
        },
      );
    }
  });

  group('each column goes by its own edit time (three devices)', () {
    late _Device c;
    final day5 = DateTime.utc(2026, 3, 5);
    DateTime at(int h, [int m = 0]) => day5.add(Duration(hours: h, minutes: m));

    setUp(() async {
      c = _Device('c', p.join(dir.path, 'c.db'), core);
      serverNow = DateTime.utc(2026, 3, 3, 21);
      await c.sync();
      c.conflicts.clear();
    });

    Future<List<Object?>> everywhere(
      String table,
      String id,
      String column,
    ) async => [
      for (final device in [a, b, c]) (await device.row(table, id))?[column],
      core.rowsOf(table)[id]?[column],
    ];

    FieldTime? serverTime(String table, String id, String column) =>
        FieldTimes.decode(
          core.rowsOf(table)[id]!['field_edited_at'],
        ).of(column);

    /// B changes the sick leave at [bAt] and C the notes at [cAt], both
    /// offline; A changes the notes at [aAt] and syncs; then B and C sync
    /// in [order], and everyone syncs twice more.
    Future<void> abc({
      required DateTime bAt,
      required DateTime cAt,
      required DateTime aAt,
      required List<_Device> order,
    }) async {
      serverNow = bAt;
      await b.edit('treatments', 't1', {'sick_leave_to': '2026-03-06'});
      serverNow = cAt;
      await c.edit('treatments', 't1', {'notes': 'from C'});
      serverNow = aAt;
      await a.edit('treatments', 't1', {'notes': 'from A'});
      serverNow = aAt.add(const Duration(minutes: 1));
      await a.sync();
      for (final device in order) {
        serverNow = serverNow.add(const Duration(minutes: 5));
        await device.sync();
      }
      serverNow = serverNow.add(const Duration(minutes: 5));
      await syncAll([a, b, c]);
    }

    for (final (name, order) in [
      ('B, then C', () => [b, c]),
      ('C, then B', () => [c, b]),
    ]) {
      test('A/B/C: an older sick-leave change does not let an older note '
          'win: $name', () async {
        await abc(bAt: at(9), cAt: at(9, 30), aAt: at(10), order: order());
        expect(
          await everywhere('treatments', 't1', 'notes'),
          List.filled(4, 'from A'),
        );
        expect(
          await everywhere('treatments', 't1', 'sick_leave_to'),
          List.filled(4, '2026-03-06'),
        );
        expect(c.conflicts.single.keptLocal, isFalse);
        expect(b.conflicts, isEmpty);
        expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(10)));
        expect(
          serverTime('treatments', 't1', 'sick_leave_to'),
          FieldTime(at(9)),
        );
      });

      test('A/B/C: a note C made after A\'s still wins: $name', () async {
        await abc(bAt: at(9), cAt: at(10, 2), aAt: at(10), order: order());
        expect(
          await everywhere('treatments', 't1', 'notes'),
          List.filled(4, 'from C'),
        );
        expect(c.conflicts.single.keptLocal, isTrue);
        expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(10, 2)));
      });
    }

    group('the same value set again later (review Minor 1, random seed '
        '107)', () {
      /// A sets the doctor to Dr. Bianchi at 19:00 and syncs; B, offline,
      /// sets Dr. Verdi at 19:18; C, which has not seen A's change, sets
      /// Dr. Bianchi too, at 21:20. C's is the latest edit.
      Future<void> sameValueLater(List<_Device> order) async {
        serverNow = at(19);
        await a.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        serverNow = at(19, 1);
        await a.sync();
        serverNow = at(19, 18);
        await b.edit('treatments', 't1', {'doctor': 'Dr. Verdi'});
        serverNow = at(21, 20);
        await c.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        for (final device in order) {
          serverNow = serverNow.add(const Duration(minutes: 5));
          await device.sync();
        }
        serverNow = serverNow.add(const Duration(minutes: 5));
        await syncAll([a, b, c]);
      }

      for (final (name, order) in [
        ('C, then B', () => [c, b]),
        ('B, then C', () => [b, c]),
      ]) {
        test('C\'s later edit wins: $name', () async {
          await sameValueLater(order());
          expect(
            await everywhere('treatments', 't1', 'doctor'),
            List.filled(4, 'Dr. Bianchi'),
          );
          expect(
            serverTime('treatments', 't1', 'doctor'),
            FieldTime(at(21, 20)),
          );
          // Settled: another round writes nothing.
          final version = core.rowsOf('treatments')['t1']!['row_version'];
          await syncAll([a, b, c]);
          expect(core.rowsOf('treatments')['t1']!['row_version'], version);
          for (final device in [a, b, c]) {
            expect(
              (await device.row('treatments', 't1'))!['sync_status'],
              SyncStatus.synced,
              reason: device.name,
            );
          }
        });
      }

      test('the same value set earlier than the server\'s time sends '
          'nothing', () async {
        serverNow = at(19);
        await a.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        serverNow = at(18);
        await c.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        serverNow = at(19, 1);
        await a.sync();
        final version = core.rowsOf('treatments')['t1']!['row_version'];
        serverNow = at(19, 5);
        await c.sync();
        expect(core.rowsOf('treatments')['t1']!['row_version'], version);
        expect(serverTime('treatments', 't1', 'doctor'), FieldTime(at(19)));
        expect(
          (await c.row('treatments', 't1'))!['sync_status'],
          SyncStatus.synced,
        );
      });

      test('a pull in between keeps the later time waiting, merged with '
          'a note made elsewhere', () async {
        serverNow = at(19);
        await a.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        serverNow = at(19, 1);
        await a.sync();
        // C sets the same value later, and pulls before it pushes.
        serverNow = at(21, 20);
        await c.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
        serverNow = at(21, 25);
        await c.pull();
        expect(
          (await c.row('treatments', 't1'))!['sync_status'],
          SyncStatus.pendingUpdate,
        );
        // A notes something meanwhile; C pulls it before it pushes.
        serverNow = at(21, 30);
        await a.edit('treatments', 't1', {'notes': 'rest'});
        await a.sync();
        serverNow = at(21, 40);
        await c.pull();
        await c.push();
        expect(serverTime('treatments', 't1', 'doctor'), FieldTime(at(21, 20)));
        expect(await everywhere('treatments', 't1', 'notes'), [
          'rest',
          'after food',
          'rest',
          'rest',
        ]);
      });
    });

    for (final (season, bAt, cAt, aAt) in [
      // Rome: 01:30 CET, 01:50 CET, then 03:10 CEST.
      (
        'spring',
        DateTime.utc(2026, 3, 29, 0, 30),
        DateTime.utc(2026, 3, 29, 0, 50),
        DateTime.utc(2026, 3, 29, 1, 10),
      ),
      // Rome: 02:20 CEST, 02:40 CEST, then 02:10 CET: A's note reads
      // earlier on the wall clock but is the later instant.
      (
        'autumn',
        DateTime.utc(2026, 10, 25, 0, 20),
        DateTime.utc(2026, 10, 25, 0, 40),
        DateTime.utc(2026, 10, 25, 1, 10),
      ),
    ]) {
      test('A/B/C across the $season change: the later instant wins the '
          'notes', () async {
        await abc(bAt: bAt, cAt: cAt, aAt: aAt, order: [b, c]);
        expect(
          await everywhere('treatments', 't1', 'notes'),
          List.filled(4, 'from A'),
        );
        final stored = FieldTimes.decode(
          (await c.row('treatments', 't1'))!['field_edited_at'],
        );
        expect(stored.of('notes'), FieldTime(aAt));
        expect(stored.of('notes')!.at.isUtc, isTrue);
      });
    }

    test('C\'s clock a day ahead: its note wins only against changes that '
        'reached the server before it did', () async {
      c.skew = const Duration(days: 1);
      serverNow = at(9);
      await b.edit('treatments', 't1', {'sick_leave_to': '2026-03-06'});
      serverNow = at(9, 30);
      await c.edit('treatments', 't1', {'notes': 'from C'});
      serverNow = at(10);
      await a.edit('treatments', 't1', {'notes': 'from A'});
      serverNow = at(10, 1);
      await a.sync();
      serverNow = at(10, 5);
      await b.sync();
      // B, offline again, changes the notes before C's change arrives.
      serverNow = at(10, 20);
      await b.edit('treatments', 't1', {'notes': 'from B'});
      serverNow = at(10, 30);
      await c.sync();
      expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(10, 30)));
      serverNow = at(10, 35);
      await syncAll([b, a, c]);
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'from C'),
      );
      expect(b.conflicts.last.keptLocal, isFalse);
      // A note made after C's change arrived wins, though C's clock read a
      // later time for its own.
      serverNow = at(10, 40);
      await a.edit('treatments', 't1', {'notes': 'A again'});
      serverNow = at(10, 41);
      await syncAll([a, b, c]);
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'A again'),
      );
    });

    test('C\'s clock two hours behind: its really later note loses, and B\'s '
        'older change in between does not help it', () async {
      c.skew = const Duration(hours: -2);
      serverNow = at(9);
      await b.edit('treatments', 't1', {'sick_leave_to': '2026-03-06'});
      serverNow = at(10);
      await a.edit('treatments', 't1', {'notes': 'from A'});
      serverNow = at(10, 1);
      await a.sync();
      serverNow = at(10, 5);
      await b.sync();
      // Really 10:30; C's clock reads 08:30.
      serverNow = at(10, 30);
      await c.edit('treatments', 't1', {'notes': 'from C'});
      serverNow = at(10, 31);
      await syncAll([c, a, b]);
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'from A'),
      );
      expect(c.conflicts.single.keptLocal, isFalse);
      expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(10)));
    });

    for (final (name, order) in [
      ('A syncs first', () => [a, b, c]),
      ('B syncs first', () => [b, a, c]),
    ]) {
      test('the app marks a dose missed on A, then a person notes it there; '
          'B took it earlier: taken, with the note: $name', () async {
        serverNow = at(7, 5);
        await b.edit('dose_logs', 'd1', {
          'status': 'taken',
          'taken_time': b.now().toIso8601String(),
        });
        // A's overdue sweep (the real one: it leaves edited_at alone),
        // then a person's note on A.
        serverNow = at(10);
        await a.open();
        final swept = await DoseLogLocalDatasource(
          now: () => a.now().toLocal(),
        ).markOverduePendingAsMissed(at(9).toLocal());
        expect(swept.changed, 1);
        serverNow = at(11);
        await a.edit('dose_logs', 'd1', {'notes': 'felt sick'});
        serverNow = at(12);
        await syncAll(order());
        expect(
          await everywhere('dose_logs', 'd1', 'status'),
          List.filled(4, 'taken'),
        );
        expect(
          await everywhere('dose_logs', 'd1', 'notes'),
          List.filled(4, 'felt sick'),
        );
        expect(serverTime('dose_logs', 'd1', 'status')!.automatic, isFalse);
      });

      test('the app marks a dose missed on A, a person notes it on B: both '
          'are kept: $name', () async {
        serverNow = at(10);
        await a.automatic('dose_logs', 'd1', {'status': 'missed'});
        serverNow = at(10, 30);
        await b.edit('dose_logs', 'd1', {'notes': 'with water'});
        serverNow = at(11);
        await syncAll(order());
        expect(
          await everywhere('dose_logs', 'd1', 'status'),
          List.filled(4, 'missed'),
        );
        expect(
          await everywhere('dose_logs', 'd1', 'notes'),
          List.filled(4, 'with water'),
        );
        expect(serverTime('dose_logs', 'd1', 'status'), isNotNull);
        expect(serverTime('dose_logs', 'd1', 'status')!.automatic, isTrue);
        expect(serverTime('dose_logs', 'd1', 'notes'), FieldTime(at(10, 30)));
        expect([...a.conflicts, ...b.conflicts], isEmpty);
      });
    }

    /// Medora 0.3.0 upserts the whole row as it holds it (here: current),
    /// with [changes] made at [when].
    Map<String, dynamic> legacyWrite(
      DateTime when,
      Map<String, Object?> changes,
    ) {
      serverNow = when;
      final json = {
        ...canonicalWire('treatments', core.rowsOf('treatments')['t1']!),
        ...changes,
        'updated_at': when.toIso8601String(),
      };
      return FakeSyncTable(
        core,
        'treatments',
      ).core.legacyUpsert('treatments', json);
    }

    test('a 0.3.0 write in between stamps only what it changed: C\'s older '
        'note still loses', () async {
      serverNow = at(9, 30);
      await c.edit('treatments', 't1', {'notes': 'from C'});
      serverNow = at(10);
      await a.edit('treatments', 't1', {'notes': 'from A'});
      serverNow = at(10, 1);
      await a.sync();
      final legacy = legacyWrite(at(10, 15), {'sick_leave_ref': 'CERT-OLD'});
      expect(legacy['write_id'], isNull);
      expect(legacy['row_version'], 4);
      serverNow = at(10, 30);
      await syncAll([c, a, b]);
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'from A'),
      );
      expect(
        await everywhere('treatments', 't1', 'sick_leave_ref'),
        List.filled(4, 'CERT-OLD'),
      );
      expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(10)));
      expect(
        serverTime('treatments', 't1', 'sick_leave_ref'),
        FieldTime(at(10, 15)),
      );
    });

    test('a 0.3.0 write in between: a note C made after A\'s still wins, '
        'though the 0.3.0 write arrived later', () async {
      serverNow = at(10);
      await a.edit('treatments', 't1', {'notes': 'from A'});
      serverNow = at(10, 1);
      await a.sync();
      serverNow = at(10, 10);
      await c.edit('treatments', 't1', {'notes': 'from C'});
      legacyWrite(at(10, 15), {'sick_leave_ref': 'CERT-OLD'});
      serverNow = at(10, 30);
      await syncAll([c, a, b]);
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'from C'),
      );
      expect(
        await everywhere('treatments', 't1', 'sick_leave_ref'),
        List.filled(4, 'CERT-OLD'),
      );
    });

    test('a row restored from a backup without the map meets the server '
        'column by column', () async {
      serverNow = at(10);
      await a.edit('treatments', 't1', {'doctor': 'Dr. Bianchi'});
      serverNow = at(10, 1);
      await a.sync();
      // B restores a 0.3.0 backup: the row was last changed at 09:00 today,
      // with a note and the doctor as they were then. No base, no edit
      // times, `updated_at` in local wall-clock time.
      final db = await b.open();
      await db.update('treatments', {
        'notes': 'restored note',
        'doctor': 'Dr. Rossi',
        'updated_at': wallClock(at(9)),
        'sync_status': SyncStatus.pendingUpdate,
        'edited_at': null,
        'field_edited_at': null,
        ...clearedSyncMeta,
      }, where: "id = 't1'");
      serverNow = at(10, 30);
      await syncAll([b, a, c]);
      // The server's note is B's from the 3rd: older than the backup's row.
      expect(
        await everywhere('treatments', 't1', 'notes'),
        List.filled(4, 'restored note'),
      );
      // The doctor changed at 10:00: newer than the backup's row.
      expect(
        await everywhere('treatments', 't1', 'doctor'),
        List.filled(4, 'Dr. Bianchi'),
      );
      expect(serverTime('treatments', 't1', 'notes'), FieldTime(at(9)));
    });
  });

  group('deletes and the rows under them (review C-1, I-1, I-2)', () {
    const epoch = '1970-01-01T00:00:00.000Z';
    final slot = DateTime.utc(2026, 3, 5, 7);

    /// The schedule on [d] no longer has [id]: the app's own, guarded
    /// delete.
    Future<void> drop(_Device d, String id) => d.automatic('dose_logs', id, {
      'delete_guard': 'if_pending',
      'deleted_at': d.now().toIso8601String(),
    }, status: SyncStatus.pendingDelete);

    /// A person deletes [id] of [table] on [d].
    Future<void> delete(_Device d, String table, String id) async {
      final db = await d.open();
      await db.update(
        table,
        {
          'sync_status': SyncStatus.pendingDelete,
          'deleted_at': d.now().toIso8601String(),
          'edited_at': d.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    /// The schedule on [d] generates [id] now.
    Future<void> generate(_Device d, String id, DateTime at) => d.insert(
      'dose_logs',
      {...generated(id, at), 'created_at': d.now().toLocal().toIso8601String()},
    );

    Future<void> take(_Device d, String id) => d.edit('dose_logs', id, {
      'status': 'taken',
      'taken_time': d.now().toIso8601String(),
    });

    /// Whether each device, then the server, holds [id] of [table] live.
    Future<List<bool>> live(
      List<_Device> devices,
      String table,
      String id,
    ) async {
      final server = core.rowsOf(table)[id];
      return [
        for (final d in devices) await d.row(table, id) != null,
        server != null && server['deleted_at'] == null,
      ];
    }

    /// Another round on every device changes nothing on the server and
    /// leaves nothing to send: nothing loops.
    Future<void> expectSettled(List<_Device> devices) async {
      Map<String, Object?> versions() => {
        for (final table in syncedTables)
          for (final row in core.rowsOf(table).values)
            '$table/${row['id']}': row['row_version'],
      };
      final before = versions();
      for (final d in [...devices, ...devices]) {
        await d.sync();
      }
      expect(versions(), before);
      for (final d in devices) {
        final db = await d.open();
        for (final table in syncedTables) {
          expect(
            await db.query(
              table,
              where: 'sync_status != ?',
              whereArgs: [SyncStatus.synced],
            ),
            isEmpty,
            reason: '${d.name} $table',
          );
        }
      }
    }

    for (final who in ['A', 'B']) {
      test('a slot dropped, then generated again on $who, stays on every '
          'device (I-1, P1)', () async {
        serverNow = DateTime.utc(2026, 3, 5, 5);
        await drop(a, 'd1');
        await a.sync();
        await b.sync();
        expect(await live([a, b], 'dose_logs', 'd1'), [false, false, false]);
        // The schedule is changed back: the same slot is generated again.
        serverNow = DateTime.utc(2026, 3, 5, 5, 30);
        final regenerating = who == 'A' ? a : b;
        await generate(regenerating, 'd1', slot);
        await syncAll(who == 'A' ? [a, b] : [b, a]);
        expect(await live([a, b], 'dose_logs', 'd1'), [true, true, true]);
        final server = core.rowsOf('dose_logs')['d1']!;
        // Still the app's own change: 0.3.0 never sees it.
        expect([server['edited_at'], server['updated_at']], [epoch, epoch]);
        await expectSettled([a, b]);
      });
    }

    for (final after in [true, false]) {
      test('a slot generated offline ${after ? 'after' : 'before'} another '
          'device dropped it ${after ? 'comes back' : 'stays dropped'} '
          '(I-1)', () async {
        final d5 = DateTime.utc(2026, 3, 6, 7);
        if (!after) {
          serverNow = DateTime.utc(2026, 3, 5, 4);
          await generate(b, 'd5', d5);
        }
        serverNow = DateTime.utc(2026, 3, 5, 4, 30);
        await generate(a, 'd5', d5);
        await a.sync();
        serverNow = DateTime.utc(2026, 3, 5, 5);
        await drop(a, 'd5');
        await a.sync();
        if (after) {
          serverNow = DateTime.utc(2026, 3, 5, 5, 30);
          await generate(b, 'd5', d5);
        }
        serverNow = DateTime.utc(2026, 3, 5, 6);
        await syncAll([b, a]);
        expect(await live([a, b], 'dose_logs', 'd5'), List.filled(3, after));
        await expectSettled([a, b]);
      });
    }

    test('a dose a person deleted is not brought back by the schedule '
        '(I-1)', () async {
      serverNow = DateTime.utc(2026, 3, 5, 5);
      await delete(a, 'dose_logs', 'd1');
      await a.sync();
      await b.sync();
      serverNow = DateTime.utc(2026, 3, 5, 5, 30);
      await generate(b, 'd1', slot);
      await syncAll([b, a]);
      expect(await live([a, b], 'dose_logs', 'd1'), [false, false, false]);
      await expectSettled([a, b]);
    });

    test(
      'a take of a dropped dose, sent after a person deleted its '
      'prescription: the delete wins, and every device syncs (C-1, P2)',
      () async {
        serverNow = DateTime.utc(2026, 3, 5, 5);
        await drop(a, 'd1');
        await a.sync();
        serverNow = DateTime.utc(2026, 3, 5, 7, 5);
        await take(b, 'd1');
        serverNow = DateTime.utc(2026, 3, 5, 8);
        await delete(a, 'prescriptions', 'p1');
        await a.sync();
        serverNow = DateTime.utc(2026, 3, 5, 9);
        await b.sync();
        final c = _Device('c', p.join(dir.path, 'c.db'), core);
        await c.sync();
        await a.sync();
        for (final (table, id) in [
          ('prescriptions', 'p1'),
          ('dose_logs', 'd0'),
          ('dose_logs', 'd1'),
        ]) {
          expect(await live([a, b, c], table, id), [
            false,
            false,
            false,
            false,
          ], reason: '$table/$id');
        }
        // B's take reached the server, and was deleted with its prescription.
        expect(core.rowsOf('dose_logs')['d1']!['status'], 'taken');
        expect(
          core
              .rowsOf('dose_logs')
              .values
              .where(
                (r) => r['prescription_id'] == 'p1' && r['deleted_at'] == null,
              ),
          isEmpty,
        );
        await expectSettled([a, b, c]);
      },
    );

    for (final kind in ['generated', 'taken']) {
      test('a dose made offline ($kind) under a prescription deleted '
          'elsewhere is deleted on every device (C-1, P2b)', () async {
        final d7 = DateTime.utc(2026, 3, 6, 7);
        serverNow = DateTime.utc(2026, 3, 6, 6);
        await generate(b, 'd7', d7);
        if (kind == 'taken') {
          serverNow = DateTime.utc(2026, 3, 6, 7, 5);
          await take(b, 'd7');
        }
        serverNow = DateTime.utc(2026, 3, 6, 8);
        await delete(a, 'prescriptions', 'p1');
        await a.sync();
        serverNow = DateTime.utc(2026, 3, 6, 9);
        await b.push();
        // The server stored it deleted, and B holds no copy of it, even
        // before its pull brings the prescription's delete.
        expect(core.rowsOf('dose_logs')['d7']!['deleted_at'], isNotNull);
        expect(await b.row('dose_logs', 'd7'), isNull);
        await b.pull();
        await a.sync();
        final c = _Device('c', p.join(dir.path, 'c.db'), core);
        await c.sync();
        expect(await live([a, b, c], 'dose_logs', 'd7'), [
          false,
          false,
          false,
          false,
        ]);
        expect(await live([a, b, c], 'prescriptions', 'p1'), [
          false,
          false,
          false,
          false,
        ]);
        await expectSettled([a, b, c]);
      });
    }

    test('a dose pulled for a prescription deleted here goes with it, and '
        'the delete reaches every device', () async {
      serverNow = DateTime.utc(2026, 3, 5, 7, 5);
      await take(a, 'd1');
      await a.sync();
      serverNow = DateTime.utc(2026, 3, 5, 7, 10);
      await delete(b, 'prescriptions', 'p1');
      // B pulls before its delete goes out.
      await b.pull();
      expect(b.pulled, contains('dose_logs/d1 deleted'));
      expect(await b.row('dose_logs', 'd1'), isNull);
      serverNow = DateTime.utc(2026, 3, 5, 8);
      await syncAll([b, a]);
      expect(await live([a, b], 'dose_logs', 'd1'), [false, false, false]);
      expect(await live([a, b], 'prescriptions', 'p1'), [false, false, false]);
      await expectSettled([a, b]);
    });

    test('a live dose the server holds under a deleted prescription is '
        'passed over by a new device, without an error', () async {
      // As a server from before the repair holds it.
      core.rowsOf('prescriptions')['p1']!['deleted_at'] =
          '2026-03-05T08:00:00.000Z';
      final c = _Device('c', p.join(dir.path, 'c.db'), core);
      serverNow = DateTime.utc(2026, 3, 5, 9);
      await c.sync();
      expect(
        c.pulled,
        containsAll(['dose_logs/d0 orphaned', 'dose_logs/d1 orphaned']),
      );
      expect(await live([c], 'dose_logs', 'd0'), [false, true]);
      expect(await c.row('treatments', 't1'), isNotNull);
    });

    test('a 0.3.0 take of a dose 0.4.0 dropped reaches every device (I-2, '
        'P4)', () async {
      serverNow = DateTime.utc(2026, 3, 5, 5);
      await drop(a, 'd1');
      await a.sync();
      await b.sync();
      serverNow = DateTime.utc(2026, 3, 5, 7, 5);
      final old = core.rowsOf('dose_logs')['d1']!;
      core.legacyUpsert('dose_logs', {
        'id': 'd1',
        'prescription_id': 'p1',
        'scheduled_time': old['scheduled_time'],
        'taken_time': serverNow.toIso8601String(),
        'status': 'taken',
        'notes': null,
        'updated_at': serverNow.toIso8601String(),
      });
      serverNow = DateTime.utc(2026, 3, 5, 8);
      await syncAll([a, b]);
      expect(await both('dose_logs', 'd1', 'status'), [
        'taken',
        'taken',
        'taken',
      ]);
      expect(await live([a, b], 'dose_logs', 'd1'), [true, true, true]);
      await expectSettled([a, b]);
    });
  });
}

/// A table whose writes land, but whose answer never arrives.
class _LosingTable extends FakeSyncTable {
  _LosingTable(super.core, super.table);

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    await super.patch(
      id,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
    throw StateError('answer lost');
  }
}
