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
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_server.dart';
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

  /// One cycle: push every pending row in foreign-key order, then pull
  /// every table to the horizon.
  Future<void> sync() async {
    final db = await open();
    for (final table in syncedTables) {
      final engine = _engine(table);
      for (final row in await db.query(
        table,
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.synced],
      )) {
        conflicts.addAll((await engine.pushRow(row, userId: 'u')).conflicts);
      }
    }
    final horizon = core.horizon;
    for (final table in syncedTables) {
      final engine = _engine(table);
      final remote = FakeSyncTable(core, table);
      while (true) {
        final rows = await remote.page(after: _keys[table], horizon: horizon);
        for (final row in rows) {
          conflicts.addAll((await engine.applyPulled(row)).conflicts);
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
      });

  /// A change the app made on its own.
  Future<void> automatic(
    String table,
    String id,
    Map<String, Object?> values, {
    String status = SyncStatus.pendingUpdate,
  }) => _write(table, id, {
    ...values,
    'edited_at': automaticEditedAt.toIso8601String(),
  }, status: status);

  Future<void> _write(
    String table,
    String id,
    Map<String, Object?> values, {
    String status = SyncStatus.pendingUpdate,
  }) async {
    final db = await open();
    final current = (await db.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    await db.update(
      table,
      {
        ...values,
        'sync_status': current['sync_status'] == SyncStatus.pendingCreate
            ? SyncStatus.pendingCreate
            : status,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
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
}
