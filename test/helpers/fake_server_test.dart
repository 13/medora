/// The fake server keeps the rules of `20260918000000_sync_v2.sql`; these
/// mirror `tools/sql/sync_v2_checks.sql`, so a fake that drifts from the
/// migration fails here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_server.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// Out-of-range stock changes, as `tools/sql/sync_v2_checks.sql` checks
/// them: (quantity before, delta, set_to, quantity after).
const stockRangeCases = <(int, int?, int?, int)>[
  (10, -3, null, 7),
  (10, -100, null, 0),
  (7, null, 20, 20),
  (20, null, -1, 0),
  (0, null, 1000000, 999999),
  (999999, null, 2147483647, 999999),
  (999999, 2147483647, null, 999999),
  (999999, -2147483648, null, 0),
  (5, 1000000, null, 999999),
  (-5, 3, null, 0),
  (2000000, -2000000, null, 999999),
  (999999, null, 20, 20),
];

void main() {
  late DateTime now;
  late FakeServerCore core;

  setUp(() {
    now = DateTime.utc(2026, 9, 16, 12);
    core = FakeServerCore(() => now);
  });

  Map<String, dynamic> med() => core.rowsOf('medications')['m1']!;

  test('a 0.3.0 insert gets version 1, no write id, its own edit time and '
      'an arrival stamp', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibuprofen',
      'quantity': 10,
      'updated_at': '2026-09-01T08:00:00.000Z',
    });
    expect(med()['row_version'], 1);
    expect(med()['write_id'], isNull);
    expect(med()['edited_at'], '2026-09-01T08:00:00.000Z');
    expect(med()['updated_at'], '2026-09-16T12:00:00.000Z');
    expect(med()['sync_xid'], greaterThanOrEqualTo(1000));
  });

  test('a 0.3.0 update counts as made on arrival and clears the write id', () {
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
    core.patch('medications', 'm1', {'write_id': 'w1', 'notes': 'x'});
    now = now.add(const Duration(minutes: 5));
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibuprofen'});
    expect(med()['row_version'], 3);
    expect(med()['write_id'], isNull);
    expect(med()['edited_at'], '2026-09-16T12:05:00.000Z');
    expect(med()['updated_at'], '2026-09-16T12:05:00.000Z');
  });

  test('a conditional update applies once; a replay matches nothing', () {
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
    final first = core.patch('medications', 'm1', {
      'notes': 'a',
      'write_id': 'w1',
      'edited_at': '2026-09-16T10:00:00.000Z',
    }, ifVersion: 1);
    expect(first!['row_version'], 2);
    expect(first['edited_at'], '2026-09-16T10:00:00.000Z');
    expect(
      core.patch('medications', 'm1', {'notes': 'a'}, ifVersion: 1),
      isNull,
    );
  });

  test(
    'a future edit time is capped at now; a repeated write id is cleared',
    () {
      core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
      core.patch('medications', 'm1', {
        'write_id': 'w2',
        'edited_at': '2099-01-01T00:00:00.000Z',
      });
      expect(med()['edited_at'], '2026-09-16T12:00:00.000Z');
      core.patch('medications', 'm1', {'notes': 'x', 'write_id': 'w2'});
      expect(med()['write_id'], isNull);
    },
  );

  test('an automatic change keeps updated_at; a real one moves it', () {
    core.insertIfAbsent('dose_logs', [
      {
        'id': 'd1',
        'status': 'pending',
        'updated_at': '1970-01-01T00:00:00.000Z',
        'write_id': 'gen',
        'edited_at': '1970-01-01T00:00:00.000Z',
      },
    ]);
    Map<String, dynamic> dose() => core.rowsOf('dose_logs')['d1']!;
    expect(dose()['updated_at'], '1970-01-01T00:00:00.000Z');
    core.patch('dose_logs', 'd1', {
      'status': 'missed',
      'write_id': 'auto',
      'edited_at': '1970-01-01T00:00:00.001Z',
    }, ifVersion: 1);
    expect(dose()['updated_at'], '1970-01-01T00:00:00.000Z');
    expect(dose()['edited_at'], '1970-01-01T00:00:00.000Z');
    core.patch('dose_logs', 'd1', {
      'status': 'taken',
      'write_id': 'real',
      'edited_at': '2026-09-16T11:59:00.000Z',
    }, ifVersion: 2);
    expect(dose()['updated_at'], '2026-09-16T12:00:00.000Z');
    expect(
      core.patch(
        'dose_logs',
        'd1',
        {'deleted_at': 'x'},
        ifStatus: 'pending',
        ifLive: true,
      ),
      isNull,
      reason: 'a guarded delete skips a taken dose',
    );
  });

  test('the horizon holds back a transaction still open', () {
    final slow = core.begin();
    slow.insert('medications', {'id': 'slow', 'name': 'Slow'});
    core.legacyUpsert('medications', {'id': 'fast', 'name': 'Fast'});
    expect(core.page('medications', horizon: core.horizon), isEmpty);
    slow.commit();
    expect(
      core.page('medications', horizon: core.horizon).map((r) => r['id']),
      ['slow', 'fast'],
    );
  });

  test('stock: applied, duplicate, clamped, counted, gone', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibu',
      'quantity': 10,
    });
    expect(core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -3), {
      'status': 'applied',
      'quantity': 7,
      'row_version': 2,
    });
    expect(core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -3), {
      'status': 'duplicate',
      'quantity': 7,
    });
    expect(
      core.applyStockChange(
        opId: 'b',
        medicationId: 'm1',
        delta: -100,
      )['quantity'],
      0,
    );
    expect(
      core.applyStockChange(
        opId: 'c',
        medicationId: 'm1',
        setTo: 20,
      )['quantity'],
      20,
    );
    expect(core.applyStockChange(opId: 'd', medicationId: 'nope', delta: -1), {
      'status': 'gone',
    });
    core.patch('medications', 'm1', {'deleted_at': '2026-09-16T12:00:00.000Z'});
    expect(core.applyStockChange(opId: 'e', medicationId: 'm1', delta: -1), {
      'status': 'gone',
    });
    expect(core.ledger.keys, ['a', 'b', 'c']);
    expect(
      () => core.applyStockChange(
        opId: 'f',
        medicationId: 'm1',
        delta: -1,
        setTo: 1,
      ),
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '22023')),
    );
  });

  test('stock: a value out of range is brought into range, as the server '
      'does, and so is the ledger entry', () {
    var n = 0;
    for (final (before, delta, setTo, after) in stockRangeCases) {
      core.rowsOf('medications')['m1'] = {
        ...?core.rowsOf('medications')['m1'],
        'id': 'm1',
        'quantity': before,
        'deleted_at': null,
        'sync_xid': 1,
        'row_version': 1,
      };
      final op = 'op${n++}';
      final answer = core.applyStockChange(
        opId: op,
        medicationId: 'm1',
        delta: delta,
        setTo: setTo,
      );
      final reason = '($before, $delta, $setTo)';
      expect(answer['status'], 'applied', reason: reason);
      expect(answer['quantity'], after, reason: reason);
      expect(med()['quantity'], after, reason: reason);
      expect(
        stockAfter(before, delta: delta, setTo: setTo),
        after,
        reason: 'the client computes the same: $reason',
      );
      final entry = core.ledger[op]!;
      expect(entry.quantityAfter, after);
      expect(entry.delta, delta?.clamp(-999999, 999999), reason: reason);
      expect(entry.setTo, setTo?.clamp(0, 999999), reason: reason);
      expect(
        core.applyStockChange(
          opId: op,
          medicationId: 'm1',
          delta: delta,
          setTo: setTo,
        ),
        {'status': 'duplicate', 'quantity': after},
        reason: 'a retry is a duplicate: $reason',
      );
    }
  });

  test('stock: the local quantity follows the server rule for every '
      'quantity the app stores', () {
    for (final (before, delta, setTo, after) in stockRangeCases) {
      if (before < 0 || before > maxStock) continue;
      final op = StockOp(
        opId: 'o',
        medicationId: 'm1',
        delta: delta,
        setTo: setTo,
        createdAt: DateTime.utc(2026),
      );
      expect(
        applyStockOps(before, [op]),
        after,
        reason: '($before, $delta, $setTo)',
      );
    }
  });

  test('stock: a medication removed from the server is gone for good, and '
      'its ledger and children go with it', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibu',
      'quantity': 5,
    });
    core.legacyUpsert('treatments', {'id': 't1', 'name': 'Flu'});
    core.legacyUpsert('prescriptions', {
      'id': 'p1',
      'treatment_id': 't1',
      'medication_id': 'm1',
    });
    core.legacyUpsert('dose_logs', {'id': 'd1', 'prescription_id': 'p1'});
    expect(
      core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -1)['status'],
      'applied',
    );
    core.purge('medications', 'm1');
    expect(core.rowsOf('medications'), isEmpty);
    expect(core.rowsOf('prescriptions'), isEmpty);
    expect(core.rowsOf('dose_logs'), isEmpty);
    expect(core.rowsOf('treatments').keys, ['t1']);
    expect(core.ledger, isEmpty);
    expect(
      core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -1),
      {'status': 'gone'},
      reason: 'a retry of an applied change',
    );
    expect(
      core.applyStockChange(opId: 'b', medicationId: 'm1', setTo: 3),
      {'status': 'gone'},
      reason: 'a new change',
    );
    expect(core.ledger, isEmpty);
  });

  test('stock: an answer that writes nothing uses no transaction id', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibu',
      'quantity': 5,
    });
    core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -1);
    final horizon = core.horizon;
    core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -1);
    core.applyStockChange(opId: 'b', medicationId: 'nope', delta: -1);
    expect(core.horizon, horizon);
    core.applyStockChange(opId: 'c', medicationId: 'm1', delta: -1);
    expect(core.horizon, horizon + 1);
  });

  group('every write moves sync_xid', () {
    late int xid;
    late int version;

    void remember(String table, String id) {
      final row = core.rowsOf(table)[id]!;
      xid = row['sync_xid'] as int;
      version = row['row_version'] as int;
    }

    void expectMoved(String table, String id) {
      final row = core.rowsOf(table)[id]!;
      expect(row['sync_xid'], greaterThan(xid));
      expect(row['row_version'], version + 1);
    }

    setUp(() {
      core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
      remember('medications', 'm1');
    });

    test('an update that changes nothing', () {
      core.patch('medications', 'm1', {});
      expectMoved('medications', 'm1');
    });

    test('a 0.3.0 upsert of the same row', () {
      core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
      expectMoved('medications', 'm1');
    });

    test('a 0.4.0 update', () {
      core.patch('medications', 'm1', {
        'notes': 'x',
        'write_id': 'w1',
        'edited_at': '2026-09-16T11:00:00.000Z',
      }, ifVersion: 1);
      expectMoved('medications', 'm1');
    });

    test('an automatic change, which keeps updated_at', () {
      final updatedAt = med()['updated_at'];
      core.patch('medications', 'm1', {
        'notes': 'x',
        'write_id': 'w1',
        'edited_at': '1970-01-01T00:00:00.000Z',
      });
      expectMoved('medications', 'm1');
      expect(med()['updated_at'], updatedAt);
    });

    test('a stock change', () {
      core.applyStockChange(opId: 'a', medicationId: 'm1', delta: 1);
      expectMoved('medications', 'm1');
    });

    test('a tombstone cascaded to a child', () {
      core.legacyUpsert('prescriptions', {'id': 'p1', 'medication_id': 'm1'});
      remember('prescriptions', 'p1');
      core.patch('medications', 'm1', {
        'deleted_at': '2026-09-16T12:00:00.000Z',
      });
      expectMoved('prescriptions', 'p1');
    });

    test('an insert ignores a sent row_version and sync_xid', () {
      core.insertIfAbsent('medications', [
        {'id': 'forged', 'name': 'F', 'row_version': 99, 'sync_xid': 1},
      ]);
      final row = core.rowsOf('medications')['forged']!;
      expect(row['row_version'], 1);
      expect(row['sync_xid'], greaterThan(xid));
    });
  });

  test('a page from a stored horizon includes rows written at it', () {
    core.legacyUpsert('medications', {'id': 'a', 'name': 'A'});
    final at = core.rowsOf('medications')['a']!['sync_xid'] as int;
    core.legacyUpsert('medications', {'id': 'b', 'name': 'B'});
    expect(
      core
          .page('medications', horizon: core.horizon, afterXid: at)
          .map((r) => r['id']),
      ['a', 'b'],
    );
    expect(
      core
          .page('medications', horizon: core.horizon, afterXid: at + 1)
          .map((r) => r['id']),
      ['b'],
    );
  });

  test('a project that answers fewer rows than asked still gives every row '
      'to a pull that ends only on an empty page', () async {
    core.rowCap = 250;
    for (var i = 0; i < 600; i++) {
      core.legacyUpsert('medications', {
        'id': 'm${i.toString().padLeft(3, '0')}',
        'name': 'M',
      });
    }
    final table = FakeSyncTable(core, 'medications');
    final horizon = core.horizon;
    final pulled = <String>[];
    PullKey? after;
    var pages = 0;
    while (true) {
      final rows = await table.page(after: after, horizon: horizon);
      pages++;
      pulled.addAll(rows.map((r) => r['id'] as String));
      final step = afterPullPage(rows, horizon: horizon);
      after = step.key;
      if (step.done) break;
    }
    expect(pulled, hasLength(600));
    expect(pulled.toSet(), hasLength(600));
    expect(pages, 4, reason: '250 + 250 + 100 + the empty page');
    expect(after, PullKey(horizon));
  });

  test('a tombstone cascades to the children as a 0.3.0 write', () {
    core.legacyUpsert('treatments', {'id': 't1', 'name': 'Flu'});
    core.legacyUpsert('prescriptions', {'id': 'p1', 'treatment_id': 't1'});
    core.patch('treatments', 't1', {
      'deleted_at': '2026-09-16T12:00:00.000Z',
      'write_id': 'w',
    });
    final p = core.rowsOf('prescriptions')['p1']!;
    expect(p['deleted_at'], '2026-09-16T12:00:00.000Z');
    expect(p['write_id'], isNull);
    expect(p['row_version'], 2);
  });

  group('edit times per column (field_edited_at), as '
      '`tools/sql/sync_v2_checks.sql` checks them', () {
    Map<String, dynamic> t() => core.rowsOf('treatments')['ft']!;
    Map<String, dynamic> map() =>
        t()['field_edited_at'] as Map<String, dynamic>;
    Map<String, Object?> entry(DateTime at, {bool auto = false}) => {
      'at': at.toUtc().toIso8601String(),
      'auto': auto,
    };
    DateTime? at(String column) {
      final raw = (map()[column] as Map?)?['at'] as String?;
      return raw == null ? null : DateTime.parse(raw);
    }

    bool? auto(String column) => (map()[column] as Map?)?['auto'] as bool?;
    DateTime hoursAgo(num h) =>
        now.subtract(Duration(minutes: (h * 60).round()));

    Map<String, dynamic>? write(
      Map<String, dynamic> changes, {
      required String writeId,
      required DateTime editedAt,
      Object? times,
    }) => core.patch('treatments', 'ft', {
      ...changes,
      'write_id': writeId,
      'edited_at': editedAt.toUtc().toIso8601String(),
      'field_edited_at': ?times,
    });

    setUp(() {
      core.insertIfAbsent('treatments', [
        {
          'id': 'ft',
          'name': 'Flu',
          'start_date': '2026-09-10',
          'notes': 'n0',
          'sick_leave_ref': 'R0',
          'doctor': 'Dr. A',
          'end_date': null,
          'sick_leave_from': null,
          'write_id': 'w0',
          'edited_at': hoursAgo(5).toIso8601String(),
          'field_edited_at': {
            'name': entry(hoursAgo(5)),
            'notes': entry(hoursAgo(5)),
            'sick_leave_ref': entry(DateTime.utc(2099)),
            'doctor': entry(DateTime.utc(1970, 1, 1, 0, 0, 0, 500)),
            'updated_at': entry(now),
            'no_such_column': entry(now),
          },
        },
      ]);
    });

    test('an insert keeps the sent times, caps a future one, marks one '
        'before 1970-01-02 automatic and drops bookkeeping', () {
      expect(at('name'), hoursAgo(5));
      expect(auto('name'), isFalse);
      expect(at('sick_leave_ref'), now);
      expect([at('doctor'), auto('doctor')], [DateTime.utc(1970), true]);
      expect(
        map().keys,
        unorderedEquals(['name', 'notes', 'sick_leave_ref', 'doctor']),
      );
    });

    test('a 0.3.0 insert has an empty map', () {
      core.legacyUpsert('treatments', {'id': 'legacy', 'name': 'Old'});
      expect(core.rowsOf('treatments')['legacy']!['field_edited_at'], isEmpty);
    });

    test('A, then B on another column, then C with an older time: the '
        'notes entry keeps A\'s time', () {
      write(
        {'notes': 'A'},
        writeId: 'a',
        editedAt: hoursAgo(1),
        times: {'notes': entry(hoursAgo(1))},
      );
      expect(at('notes'), hoursAgo(1));
      write(
        {'sick_leave_from': '2026-09-11'},
        writeId: 'b',
        editedAt: hoursAgo(4),
        times: {'sick_leave_from': entry(hoursAgo(4))},
      );
      expect(at('notes'), hoursAgo(1));
      expect(at('sick_leave_from'), hoursAgo(4));
      expect(t()['edited_at'], hoursAgo(4).toIso8601String());
      write(
        {'notes': 'C'},
        writeId: 'c',
        editedAt: hoursAgo(3),
        times: {'notes': entry(hoursAgo(3))},
      );
      expect(t()['notes'], 'C');
      expect(at('notes'), hoursAgo(1));
    });

    test('a future time is capped; an automatic change keeps the time and '
        'updated_at; a person\'s change after it clears the flag', () {
      now = now.add(const Duration(minutes: 1));
      write(
        {'notes': 'D'},
        writeId: 'd',
        editedAt: now,
        times: {'notes': entry(DateTime.utc(2099))},
      );
      expect([at('notes'), auto('notes')], [now, false]);
      final arrived = now;
      final updatedAt = t()['updated_at'];
      now = now.add(const Duration(minutes: 1));
      write(
        {'notes': 'auto'},
        writeId: 'e',
        editedAt: DateTime.utc(1970),
        times: {'notes': entry(DateTime.utc(1970), auto: true)},
      );
      expect([at('notes'), auto('notes')], [arrived, true]);
      expect(t()['updated_at'], updatedAt);
      write(
        {'doctor': 'Dr. auto'},
        writeId: 'f',
        editedAt: DateTime.utc(1970),
        times: {'doctor': entry(now, auto: true)},
      );
      expect([at('doctor'), auto('doctor')], [DateTime.utc(1970), true]);
      write(
        {'notes': 'E'},
        writeId: 'g',
        editedAt: hoursAgo(2),
        times: {'notes': entry(hoursAgo(2))},
      );
      expect([at('notes'), auto('notes')], [arrived, false]);
    });

    test('one write, three columns: each gets the time sent for it, a column '
        'sent without one the row\'s, the rest the inserted row\'s', () {
      core.insertIfAbsent('treatments', [
        {
          'id': 'ft2',
          'name': 'Cold',
          'notes': null,
          'end_date': null,
          'sick_leave_ref': null,
          'write_id': 'c1',
          'edited_at': hoursAgo(6).toIso8601String(),
        },
      ]);
      core.patch('treatments', 'ft2', {
        'notes': 'n',
        'end_date': '2026-09-13',
        'sick_leave_ref': 'R',
        'write_id': 'c2',
        'edited_at': hoursAgo(1 / 6).toIso8601String(),
        'field_edited_at': {
          'notes': entry(hoursAgo(2)),
          'end_date': entry(hoursAgo(1 / 6), auto: true),
        },
      });
      final m = core.rowsOf('treatments')['ft2']!['field_edited_at'] as Map;
      expect(m['notes'], entry(hoursAgo(2)));
      expect(m['end_date'], entry(hoursAgo(6), auto: true));
      expect(m['sick_leave_ref'], entry(hoursAgo(1 / 6)));
      expect(m['name'], entry(hoursAgo(6)));
    });

    test('an entry for an unchanged column is ignored; a changed column '
        'without one takes the row time; a map that is not an object is '
        'none', () {
      write(
        {'name': 'Flu', 'doctor': 'Dr. B'},
        writeId: 'h',
        editedAt: hoursAgo(0.5),
        times: {'name': entry(now)},
      );
      expect(at('name'), hoursAgo(5));
      expect([at('doctor'), auto('doctor')], [hoursAgo(0.5), false]);
      write(
        {'doctor': 'Dr. C'},
        writeId: 'i',
        editedAt: hoursAgo(0.25),
        times: ['doctor'],
      );
      expect(at('doctor'), hoursAgo(0.25));
      expect(t()['field_edited_at'], isA<Map<String, dynamic>>());
    });

    test('a 0.3.0 upsert stamps only the columns it changes, on arrival, '
        'and a legacy writer\'s map is never read', () {
      final before = Map.of(map());
      now = now.add(const Duration(minutes: 1));
      core.legacyUpsert('treatments', {
        'id': 'ft',
        'name': 'Flu',
        'start_date': '2026-09-10',
        'notes': 'n0',
        'end_date': '2026-09-12',
        'updated_at': '2026-09-01T00:00:00.000Z',
      });
      expect([at('end_date'), auto('end_date')], [now, false]);
      expect(Map.of(map())..remove('end_date'), before);
      core.patch('treatments', 'ft', {
        'notes': 'F',
        'field_edited_at': {'notes': entry(DateTime.utc(2000))},
      });
      expect(at('notes'), now);
      expect(t()['write_id'], isNull);
    });

    test('a row from before the migration is filled by its first update', () {
      core.legacyUpsert('medications', {
        'id': 'old',
        'name': 'Old',
        'notes': 'n',
        'quantity': 3,
      });
      final old = core.rowsOf('medications')['old']!
        ..['edited_at'] = null
        ..['updated_at'] = '2026-01-01T00:00:00.000Z'
        ..['field_edited_at'] = <String, dynamic>{};
      expect(old['field_edited_at'], isEmpty);
      core.patch('medications', 'old', {'notes': 'changed by 0.3.0'});
      final m = core.rowsOf('medications')['old']!['field_edited_at'] as Map;
      expect(m['name'], {'at': '2026-01-01T00:00:00.000Z', 'auto': false});
      expect(m['notes'], {'at': _iso(now), 'auto': false});
      for (final key in [
        'quantity',
        'updated_at',
        'id',
        'edited_at',
        'field_edited_at',
        'write_id',
      ]) {
        expect(m.containsKey(key), isFalse, reason: key);
      }
    });

    test('a stock change leaves the map alone; a cascaded tombstone has no '
        'edit time of its own', () {
      core.legacyUpsert('medications', {
        'id': 'm1',
        'name': 'Ibu',
        'quantity': 5,
      });
      core.patch('medications', 'm1', {'notes': 'x', 'write_id': 'w'});
      final before = Map.of(med()['field_edited_at'] as Map);
      expect(before, isNotEmpty);
      core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -1);
      expect(med()['field_edited_at'], before);
      core.legacyUpsert('prescriptions', {
        'id': 'p1',
        'medication_id': 'm1',
        'dosage': '1',
      });
      core.patch('medications', 'm1', {'deleted_at': _iso(now)});
      final p = core.rowsOf('prescriptions')['p1']!['field_edited_at'] as Map;
      expect(p.containsKey('deleted_at'), isFalse);
      expect(p.containsKey('dosage'), isTrue);
    });
  });
}
