/// The fake server and the migration keep the same bookkeeping for the same
/// writes.
///
/// [parityScript] is a list of writes as clients send them (0.3.0 upserts,
/// 0.4.0 inserts and updates, deletes that cascade). This test runs it
/// through [FakeServerCore] and writes the same writes, with what the fake
/// answered after each one, as `tools/sql/fake_server_parity.sql`.
/// `tools/check_supabase_sql.sh` runs that file against the real migration,
/// where every step asserts that Postgres answers the same.
///
/// So the two cannot drift apart unnoticed:
/// - a change to the fake or to the script changes the generated file, and
///   this test fails until the file is written again:
///   `MEDORA_WRITE_PARITY_SQL=1 fvm flutter test test/helpers/fake_server_parity_test.dart`;
/// - a change to the migration fails the SQL check.
///
/// What is compared per row: `row_version`, whether `write_id` is set,
/// `edited_at`, `updated_at`, whether the row is deleted, and the whole
/// `field_edited_at` map. A time the server stamped on arrival is written
/// `@<step>` on both sides (the fake's clock and Postgres' `now()` differ);
/// every other time is compared as a UTC instant.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

const parityFile = 'tools/sql/fake_server_parity.sql';

enum ParityKind { insert, update, upsert }

/// One write of the script, and the rows it checks afterwards.
class ParityStep {
  const ParityStep.insert(this.label, this.table, this.values, {this.check})
    : kind = ParityKind.insert,
      id = null;

  const ParityStep.update(
    this.label,
    this.table,
    this.id,
    this.values, {
    this.check,
  }) : kind = ParityKind.update;

  /// A 0.3.0 upsert: insert, or on conflict set the sent columns.
  const ParityStep.upsert(this.label, this.table, this.values, {this.check})
    : kind = ParityKind.upsert,
      id = null;

  final String label;
  final ParityKind kind;
  final String table;
  final String? id;
  final Map<String, Object?> values;

  /// `(table, id)` of the rows to compare; the written row when null.
  final List<(String, String)>? check;

  String get rowId => id ?? values['id']! as String;
  List<(String, String)> get checked => check ?? [(table, rowId)];
}

String _uuid(int n) =>
    '00000000-0000-0000-0000-${n.toString().padLeft(12, '0')}';

Map<String, Object?> _at(String at, {bool auto = false}) => {
  'at': at,
  'auto': auto,
};

const _jan = '2020-01-01T00:00:00.000Z';
const _feb = '2020-02-01T00:00:00.000Z';
const _mar = '2020-03-01T00:00:00.000Z';
const _apr = '2020-04-01T00:00:00.000Z';
const _may = '2020-05-01T00:00:00.000Z';
const _future = '2099-01-01T00:00:00.000Z';
const _epoch = '1970-01-01T00:00:00.000Z';

/// The writes both servers get, in order.
final parityScript = <ParityStep>[
  const ParityStep.upsert(
    '0.3.0 creates a treatment naming three columns: an empty map',
    'treatments',
    {
      'id': 'par-t1',
      'name': 'Flu',
      'start_date': '2020-01-01',
      'updated_at': _jan,
    },
  ),
  ParityStep.update(
    'a 0.4.0 device changes the doctor: the first update fills every other '
        'column, named or not, with the row time',
    'treatments',
    'par-t1',
    {
      'doctor': 'Dr. A',
      'write_id': _uuid(1),
      'edited_at': _feb,
      'field_edited_at': {'doctor': _at(_feb)},
    },
  ),
  const ParityStep.upsert(
    '0.3.0 sends the row again with notes: only notes is stamped, on arrival',
    'treatments',
    {
      'id': 'par-t1',
      'name': 'Flu',
      'start_date': '2020-01-01',
      'notes': 'n',
      'updated_at': _jan,
    },
  ),
  ParityStep.update(
    'a 0.4.0 write, then one repeating its write id: that one is legacy and '
        'its map is not read',
    'treatments',
    'par-t1',
    {
      'sick_leave_ref': 'R1',
      'write_id': _uuid(2),
      'edited_at': _mar,
      'field_edited_at': {'sick_leave_ref': _at(_mar)},
    },
  ),
  ParityStep.update('the repeated write id', 'treatments', 'par-t1', {
    'sick_leave_ref': 'R2',
    'write_id': _uuid(2),
    'edited_at': _mar,
    'field_edited_at': {'sick_leave_ref': _at(_jan)},
  }),
  ParityStep.insert(
    '0.4.0 inserts with times: one kept, a future one capped, an early one '
        'automatic, bookkeeping and unknown keys dropped',
    'treatments',
    {
      'id': 'par-t2',
      'name': 'Cold',
      'start_date': '2020-03-01',
      'notes': 'x',
      'doctor': 'D',
      'sick_leave_ref': 'R',
      'write_id': _uuid(3),
      'edited_at': _mar,
      'field_edited_at': {
        'name': _at(_mar),
        'notes': _at(_future),
        'doctor': _at('1970-01-01T00:00:00.500Z'),
        'updated_at': _at(_mar),
        'no_such_column': _at(_mar),
      },
    },
  ),
  ParityStep.update(
    'an automatic change keeps the time, and updated_at',
    'treatments',
    'par-t2',
    {
      'notes': 'auto',
      'write_id': _uuid(4),
      'edited_at': _epoch,
      'field_edited_at': {'notes': _at(_epoch, auto: true)},
    },
  ),
  ParityStep.update(
    'one write: a column with its own time, one flagged automatic, one with '
        'no time (the row time), and a later person\'s entry for an '
        'unchanged column, which moves it',
    'treatments',
    'par-t2',
    {
      'name': 'Cold',
      'end_date': '2020-03-05',
      'is_active': false,
      'sick_leave_from': '2020-03-02',
      'write_id': _uuid(5),
      'edited_at': '2020-03-04T00:00:00.000Z',
      'field_edited_at': {
        'name': _at('2020-03-09T00:00:00.000Z'),
        'end_date': _at('2020-03-03T00:00:00.000Z', auto: true),
        'is_active': _at('2020-03-02T00:00:00.000Z'),
      },
    },
  ),
  ParityStep.update(
    'the same values again: an older entry and an automatic one for '
        'unchanged columns are ignored',
    'treatments',
    'par-t2',
    {
      'name': 'Cold',
      'is_active': false,
      'sick_leave_ref': 'R2',
      'write_id': _uuid(90),
      'edited_at': '2020-03-10T00:00:00.000Z',
      'field_edited_at': {
        'name': _at('2020-03-08T00:00:00.000Z'),
        'is_active': _at('2020-03-10T00:00:00.000Z', auto: true),
        'sick_leave_ref': _at('2020-03-10T00:00:00.000Z'),
      },
    },
  ),
  ParityStep.update(
    'a person\'s older time never replaces the held one, and clears the '
        'automatic flag',
    'treatments',
    'par-t2',
    {
      'notes': 'older',
      'write_id': _uuid(6),
      'edited_at': _feb,
      'field_edited_at': {'notes': _at(_feb)},
    },
  ),
  const ParityStep.upsert('0.3.0 creates a medication', 'medications', {
    'id': 'par-m1',
    'name': 'Ibuprofen',
    'quantity': 10,
  }),
  const ParityStep.upsert('0.3.0 creates a prescription', 'prescriptions', {
    'id': 'par-p1',
    'treatment_id': 'par-t1',
    'medication_id': 'par-m1',
    'dosage': '1 tablet',
    'start_time': '2020-01-01T08:00:00.000Z',
  }),
  ParityStep.insert(
    '0.4.0 inserts a generated dose: automatic, updated_at kept',
    'dose_logs',
    {
      'id': 'par-d1',
      'prescription_id': 'par-p1',
      'scheduled_time': '2020-01-01T08:00:00.000Z',
      'status': 'pending',
      'updated_at': _epoch,
      'write_id': _uuid(7),
      'edited_at': _epoch,
      'field_edited_at': <String, Object?>{},
    },
  ),
  ParityStep.update(
    'a person takes it: the fill marks the untouched columns automatic',
    'dose_logs',
    'par-d1',
    {
      'status': 'taken',
      'taken_time': _apr,
      'write_id': _uuid(8),
      'edited_at': _apr,
      'field_edited_at': {'status': _at(_apr), 'taken_time': _at(_apr)},
    },
  ),
  ParityStep.insert('0.4.0 inserts a second generated dose', 'dose_logs', {
    'id': 'par-d2',
    'prescription_id': 'par-p1',
    'scheduled_time': '2020-01-01T16:00:00.000Z',
    'status': 'pending',
    'updated_at': _epoch,
    'write_id': _uuid(9),
    'edited_at': _epoch,
    'field_edited_at': <String, Object?>{},
  }),
  ParityStep.update(
    'a stock change leaves the map alone',
    'medications',
    'par-m1',
    {'quantity': 9, 'write_id': _uuid(10)},
  ),
  ParityStep.update(
    'the schedule drops the second dose: the app\'s own tombstone',
    'dose_logs',
    'par-d2',
    {'deleted_at': _apr, 'write_id': _uuid(11), 'edited_at': _epoch},
  ),
  const ParityStep.upsert(
    '0.3.0 re-sends the dropped dose with a note: still the app\'s tombstone',
    'dose_logs',
    {
      'id': 'par-d2',
      'prescription_id': 'par-p1',
      'scheduled_time': '2020-01-01T16:00:00.000Z',
      'status': 'pending',
      'notes': 'n',
      'updated_at': _apr,
    },
  ),
  const ParityStep.upsert(
    '0.3.0 takes the dropped dose: it comes back as a person\'s change',
    'dose_logs',
    {
      'id': 'par-d2',
      'prescription_id': 'par-p1',
      'scheduled_time': '2020-01-01T16:00:00.000Z',
      'status': 'taken',
      'taken_time': _apr,
      'notes': 'n',
      'updated_at': _apr,
    },
  ),
  ParityStep.update(
    'a person deletes the treatment: the tombstone cascades to the '
        'prescription and its doses as the app\'s own change',
    'treatments',
    'par-t1',
    {'deleted_at': _may, 'write_id': _uuid(12), 'edited_at': _may},
    check: const [
      ('treatments', 'par-t1'),
      ('prescriptions', 'par-p1'),
      ('dose_logs', 'par-d1'),
      ('dose_logs', 'par-d2'),
    ],
  ),
  ParityStep.insert(
    'a device that has not heard of it sends a generated dose: stored '
        'deleted',
    'dose_logs',
    {
      'id': 'par-d3',
      'prescription_id': 'par-p1',
      'scheduled_time': '2020-01-02T08:00:00.000Z',
      'status': 'pending',
      'updated_at': _epoch,
      'write_id': _uuid(13),
      'edited_at': _epoch,
      'field_edited_at': <String, Object?>{},
    },
  ),
  ParityStep.update(
    'and brings the cascaded dose back with a note: stored deleted',
    'dose_logs',
    'par-d1',
    {
      'deleted_at': null,
      'notes': 'after food',
      'write_id': _uuid(14),
      'edited_at': _may,
      'field_edited_at': {'notes': _at(_may)},
    },
  ),
  const ParityStep.upsert(
    '0.3.0 skips a cascaded dose: brought back, then deleted with its '
        'parent again',
    'dose_logs',
    {
      'id': 'par-d2',
      'prescription_id': 'par-p1',
      'scheduled_time': '2020-01-01T16:00:00.000Z',
      'status': 'skipped',
      'notes': 'n',
      'updated_at': _may,
    },
  ),
  ParityStep.insert(
    'a prescription sent under the deleted treatment: stored deleted',
    'prescriptions',
    {
      'id': 'par-p2',
      'treatment_id': 'par-t1',
      'medication_id': 'par-m1',
      'dosage': '2 tablets',
      'start_time': '2020-05-02T08:00:00.000Z',
      'write_id': _uuid(15),
      'edited_at': _may,
      'field_edited_at': <String, Object?>{},
    },
  ),
];

/// The step whose arrival the fake's clock gives while it runs.
DateTime _arrival(int step) => DateTime.utc(2021).add(Duration(hours: step));

/// [raw] as the parity files write it: `@<step>` for a step's arrival,
/// otherwise the UTC instant with milliseconds.
String? _time(Object? raw, int steps) {
  if (raw == null) return null;
  final at = DateTime.parse(raw as String).toUtc();
  for (var k = steps; k >= 0; k--) {
    if (at.isAtSameMomentAs(_arrival(k))) return '@$k';
  }
  return at.toIso8601String();
}

Map<String, Object?> _snapshot(Map<String, dynamic> row, int steps) {
  final times = row['field_edited_at'] as Map;
  return {
    'row_version': row['row_version'],
    'write_id': row['write_id'] != null,
    'edited_at': _time(row['edited_at'], steps),
    'updated_at': _time(row['updated_at'], steps),
    'deleted': row['deleted_at'] != null,
    'field_edited_at': <String, Object?>{
      for (final key in times.keys.map((k) => '$k').toList()..sort())
        key: <String, Object?>{
          'at': _time((times[key] as Map)['at'], steps),
          'auto': (times[key] as Map)['auto'],
        },
    },
  };
}

/// Runs [script] through the fake: each step's expected rows.
List<List<Map<String, Object?>>> runOnFake(List<ParityStep> script) {
  var step = 0;
  final core = FakeServerCore(() => _arrival(step));
  final results = <List<Map<String, Object?>>>[];
  for (final (i, s) in script.indexed) {
    step = i;
    final values = Map<String, dynamic>.of(s.values);
    switch (s.kind) {
      case ParityKind.insert:
        core.insertIfAbsent(s.table, [values]);
      case ParityKind.update:
        core.patch(s.table, s.id!, values);
      case ParityKind.upsert:
        core.legacyUpsert(s.table, values);
    }
    results.add([
      for (final (table, id) in s.checked)
        _snapshot(core.rowsOf(table)[id]!, i),
    ]);
  }
  return results;
}

String _literal(Object? value) => switch (value) {
  null => 'null',
  bool() || num() => '$value',
  Map() => "'${jsonEncode(value).replaceAll("'", "''")}'::jsonb",
  _ => "'${'$value'.replaceAll("'", "''")}'",
};

String _statement(ParityStep s) {
  final columns = s.values.keys.toList();
  final values = [for (final c in columns) _literal(s.values[c])];
  switch (s.kind) {
    case ParityKind.insert:
      return 'insert into public.${s.table} (${columns.join(', ')})\n'
          '  values (${values.join(', ')})\n'
          '  on conflict (id) do nothing;';
    case ParityKind.upsert:
      final set = [
        for (final c in columns)
          if (c != 'id') '$c = excluded.$c',
      ];
      return 'insert into public.${s.table} (${columns.join(', ')})\n'
          '  values (${values.join(', ')})\n'
          '  on conflict (id) do update set ${set.join(', ')};';
    case ParityKind.update:
      final set = [for (final (i, c) in columns.indexed) '$c = ${values[i]}'];
      return 'update public.${s.table} set ${set.join(', ')}\n'
          '  where id = ${_literal(s.id)};';
  }
}

String _encodeSorted(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => value is Map
    ? {
        for (final key in value.keys.map((k) => '$k').toList()..sort())
          key: _sorted(value[key]),
      }
    : value;

/// The SQL file for [script] and the fake's [results].
String paritySql(
  List<ParityStep> script,
  List<List<Map<String, Object?>>> results,
) {
  final out = StringBuffer('''
-- GENERATED by test/helpers/fake_server_parity_test.dart. Do not edit:
-- change the script or the fake there, then write this file again with
--   MEDORA_WRITE_PARITY_SQL=1 fvm flutter test test/helpers/fake_server_parity_test.dart
--
-- The same writes the test sends to the fake server, each followed by the
-- rows the fake held afterwards. Run by tools/check_supabase_sql.sh after
-- every migration: any row where Postgres differs from the fake stops it.
-- `@<step>` is the time that step arrived (its now()).
\\set ON_ERROR_STOP on

create temp table parity_now (step int primary key, at timestamptz not null);

create function pg_temp.parity_time(t timestamptz) returns text language sql as \$\$
  select case when t is null then null else coalesce(
    (select '@' || step from parity_now where at = t order by step desc limit 1),
    to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) end
\$\$;

create function pg_temp.parity_row(p_table text, p_id text) returns jsonb
language plpgsql as \$\$
declare
  r jsonb;
  m jsonb := '{}';
  k text;
begin
  execute format('select to_jsonb(t) from public.%I t where id = \$1', p_table)
    into r using p_id;
  for k in select jsonb_object_keys(r->'field_edited_at') loop
    m := m || jsonb_build_object(k, jsonb_build_object(
      'at', pg_temp.parity_time((r->'field_edited_at'->k->>'at')::timestamptz),
      'auto', r->'field_edited_at'->k->'auto'));
  end loop;
  return jsonb_build_object(
    'row_version', r->'row_version',
    'write_id', r->>'write_id' is not null,
    'edited_at', pg_temp.parity_time((r->>'edited_at')::timestamptz),
    'updated_at', pg_temp.parity_time((r->>'updated_at')::timestamptz),
    'deleted', r->>'deleted_at' is not null,
    'field_edited_at', m);
end
\$\$;
''');
  for (final (i, s) in script.indexed) {
    out
      ..writeln()
      ..writeln('-- Step $i: ${s.label}')
      ..writeln('begin;')
      ..writeln('insert into parity_now values ($i, now());')
      ..writeln(_statement(s))
      ..writeln('commit;')
      ..writeln(r'do $$ begin');
    for (final (j, (table, id)) in s.checked.indexed) {
      final want = _encodeSorted(results[i][j]).replaceAll("'", "''");
      out
        ..writeln(
          "  assert pg_temp.parity_row('$table', '$id') = '$want'::jsonb,",
        )
        ..writeln(
          "    format('parity step $i, $table/$id: postgres %s', "
          "pg_temp.parity_row('$table', '$id'));",
        );
    }
    out.writeln(r'end $$;');
  }
  out
    ..writeln()
    ..writeln("select 'fake server parity passed' as result;");
  return out.toString();
}

void main() {
  test('the parity script gives the rows the SQL file expects', () {
    final sql = paritySql(parityScript, runOnFake(parityScript));
    final file = File(parityFile);
    if (Platform.environment['MEDORA_WRITE_PARITY_SQL'] == '1') {
      file.writeAsStringSync(sql);
    }
    expect(
      file.existsSync() ? file.readAsStringSync() : '',
      sql,
      reason:
          'the fake or the script changed: write $parityFile again '
          '(MEDORA_WRITE_PARITY_SQL=1) and run tools/check_supabase_sql.sh',
    );
  });

  test('the script checks what it is meant to', () {
    final results = runOnFake(parityScript);
    Map<String, Object?> after(String label, [int row = 0]) =>
        results[parityScript.indexWhere((s) => s.label.startsWith(label))][row];
    Map<String, Object?> times(Map<String, Object?> row) =>
        Map<String, Object?>.from(row['field_edited_at']! as Map);

    expect(times(results[0][0]), isEmpty);
    // A column the 0.3.0 insert never named is filled like the others.
    final filled = times(after('a 0.4.0 device changes the doctor'));
    expect(filled['notes'], {'at': _jan, 'auto': false});
    expect(filled['sick_leave_ref'], {'at': _jan, 'auto': false});
    expect(filled['doctor'], {'at': _feb, 'auto': false});
    expect(times(after('0.3.0 sends the row again'))['notes'], {
      'at': '@2',
      'auto': false,
    });
    expect(times(after('the repeated write id'))['sick_leave_ref'], {
      'at': '@4',
      'auto': false,
    });
    final inserted = times(after('0.4.0 inserts with times'));
    expect(inserted.keys, ['doctor', 'name', 'notes']);
    expect(inserted['notes'], {'at': '@5', 'auto': false});
    expect(inserted['doctor'], {'at': _epoch, 'auto': true});

    final noted = after('0.3.0 re-sends the dropped dose');
    expect([noted['deleted'], noted['edited_at']], [true, _epoch]);
    expect(after('0.3.0 takes the dropped dose')['deleted'], isFalse);
    final cascade = parityScript.indexWhere(
      (s) => s.label.startsWith('a person deletes the treatment'),
    );
    for (final row in results[cascade].skip(1)) {
      expect([row['deleted'], row['edited_at']], [true, _epoch]);
    }
    for (final label in [
      'a device that has not heard of it',
      'and brings the cascaded dose back',
      '0.3.0 skips a cascaded dose',
      'a prescription sent under the deleted treatment',
    ]) {
      expect(after(label)['deleted'], isTrue, reason: label);
      expect(after(label)['edited_at'], _epoch, reason: label);
    }
  });
}
