/// The fake server keeps the rules of `20260918000000_sync_v2.sql`; these
/// mirror `tools/sql/sync_v2_checks.sql`, so a fake that drifts from the
/// migration fails here.
library;

import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

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

  test('stock: applied, duplicate, clamped, counted, missing, gone', () {
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
      'status': 'missing',
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
      throwsArgumentError,
    );
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
}
