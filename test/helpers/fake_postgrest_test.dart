/// The fake PostgREST answers the app's requests the way a local Supabase
/// does (checked against `supabase start`, CLI 2.117.0; see
/// `.superpowers/sdd/v2-task-8-report.md`), and refuses any other request.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_postgrest.dart';
import 'fake_remotes.dart';

void main() {
  late FakeServerCore core;
  late FakePostgrest wire;
  var now = DateTime.utc(2026, 3, 5, 8, 0, 0, 500);

  setUp(() {
    now = DateTime.utc(2026, 3, 5, 8, 0, 0, 500);
    core = FakeServerCore(() => now);
    wire = FakePostgrest(core);
  });

  Future<void> seedSchedule() async {
    await wire.table('medications').insertIfAbsent([
      {'id': 'm1', 'user_id': 'u', 'name': 'Ibuprofen'},
    ]);
    await wire.table('treatments').insertIfAbsent([
      {'id': 't1', 'user_id': 'u', 'name': 'Flu', 'start_date': '2026-03-01'},
    ]);
    await wire.table('prescriptions').insertIfAbsent([
      {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1',
        'dosage_amount': 1.0,
        'start_time': '2026-03-01T08:00:00.000',
      },
    ]);
    await wire.table('dose_logs').insertIfAbsent([
      for (var i = 0; i < 3; i++)
        {
          'id': 'd$i',
          'prescription_id': 'p1',
          'scheduled_time': DateTime.utc(2026, 3, 1, 8 + i).toIso8601String(),
          'status': 'pending',
          'write_id': 'w$i',
          'edited_at': DateTime.utc(1970).toIso8601String(),
          'updated_at': DateTime.utc(1970).toIso8601String(),
          'field_edited_at': <String, Object?>{},
        },
    ]);
  }

  group('answers as Postgres writes them', () {
    test('times in UTC with +00:00, trailing zeros of the fraction '
        'dropped, a time without an offset read as UTC', () async {
      await seedSchedule();
      final p = (await wire.table('prescriptions').fetch('p1'))!;
      expect(p['start_time'], '2026-03-01T08:00:00+00:00');
      expect(p['created_at'], '2026-03-05T08:00:00.5+00:00');
      expect(p['dosage_amount'], 1);
      expect(p['dosage_amount'], isA<int>());
      final d = (await wire.table('dose_logs').fetch('d1'))!;
      expect(d['scheduled_time'], '2026-03-01T09:00:00+00:00');
      expect(d['edited_at'], '1970-01-01T00:00:00+00:00');
      expect(d['taken_time'], isNull);
      now = DateTime.utc(2026, 3, 5, 9, 0, 0, 0, 120);
      final taken = (await wire.table('dose_logs').patch('d1', {
        'status': 'taken',
        'taken_time': '2026-03-05T08:59:00.000Z',
        'write_id': 'w-take',
        'edited_at': '2026-03-05T08:59:00.000Z',
        'field_edited_at': {
          'status': {'at': '2026-03-05T08:59:00.000Z', 'auto': false},
        },
      }, ifVersion: 1))!;
      expect(taken['taken_time'], '2026-03-05T08:59:00+00:00');
      expect(taken['updated_at'], '2026-03-05T09:00:00.00012+00:00');
      expect((taken['field_edited_at'] as Map)['status'], {
        'at': '2026-03-05T08:59:00+00:00',
        'auto': false,
      });
      // The core keeps what it stored; only the answer is written anew.
      expect(
        core.rowsOf('dose_logs')['d1']!['taken_time'],
        isNot(contains('+')),
      );
    });

    test('the wipe marker in the same format', () async {
      core.deleteAllData();
      final state = await wire.client().rpc<dynamic>('medora_sync_state');
      expect((state as Map)['wipe'], {
        'generation': 1,
        'wiped_at': '2026-03-05T08:00:00.5+00:00',
      });
      final again = await wire.client().rpc<dynamic>('medora_delete_all_data');
      expect(again, {
        'generation': 2,
        'wiped_at': '2026-03-05T08:00:00.5+00:00',
      });
    });

    test('errors with the codes and texts PostgREST sends', () async {
      await seedSchedule();
      final client = wire.client();
      await expectLater(
        wire.table('medications').patch('m1', {'nope': 1}),
        throwsA(
          isA<MissingColumnException>()
              .having((e) => e.column, 'column', 'nope')
              .having(
                (e) => e.cause.message,
                'message',
                "Could not find the 'nope' column of 'medications' in the "
                    'schema cache',
              ),
        ),
      );
      await expectLater(
        client
            .from('medications')
            .update({'name': 'x'})
            .eq('id', 'missing')
            .select()
            .single(),
        throwsA(
          isA<PostgrestException>()
              .having((e) => e.code, 'code', 'PGRST116')
              .having(
                (e) => e.message,
                'message',
                'Cannot coerce the result to a single JSON object',
              ),
        ),
      );
      await expectLater(
        client.rpc<dynamic>('medora_nope'),
        throwsA(
          isA<PostgrestException>()
              .having((e) => e.code, 'code', 'PGRST202')
              .having(
                (e) => e.message,
                'message',
                'Could not find the function public.medora_nope without '
                    'parameters in the schema cache',
              ),
        ),
      );
      await expectLater(
        client.rpc<dynamic>(
          'apply_stock_change',
          params: {
            'p_op_id': 'op',
            'p_medication_id': 'm1',
            'p_delta': null,
            'p_set_to': null,
          },
        ),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '22023'),
        ),
      );
      await expectLater(
        client.from('nope').select(),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', 'PGRST205'),
        ),
      );
    });
  });

  group('the requests the app sends', () {
    test('a bulk update is one PATCH by id=in.(…) that keeps its '
        'conditions per row, counted as one bulk write', () async {
      await seedSchedule();
      await wire.table('dose_logs').patch('d0', {
        'status': 'taken',
        'write_id': 'w-take',
      }, ifVersion: 1);
      wire.log.clear();
      core.requests.clear();
      final written = await wire
          .table('dose_logs')
          .patchMany(
            ['d0', 'd1', 'd2', 'missing'],
            {'status': 'missed', 'write_id': 'w-sweep'},
            ifVersion: 1,
            ifStatus: 'pending',
            ifLive: true,
          );
      expect(written.map((r) => r['id']), unorderedEquals(['d1', 'd2']));
      expect(written.first['prescriptions'], {
        'id': 'p1',
        'medications': {'name': 'Ibuprofen'},
      });
      expect(wire.log, [
        'PATCH /rest/v1/dose_logs?id=in.%28%22d0%22%2C%22d1%22%2C%22d2%22%2C'
            '%22missing%22%29&row_version=eq.1&status=eq.pending'
            '&deleted_at=is.null'
            '&select=%2A%2Cprescriptions%28id%2Cmedications%28name%29%29',
      ]);
      expect(core.requests, ['dose_logs:patchMany']);
      expect(core.rowsOf('dose_logs')['d0']!['status'], 'taken');
    });

    test('a read by ids is one GET, counted as one', () async {
      await seedSchedule();
      core.requests.clear();
      final rows = await wire.table('dose_logs').fetchMany(['d0', 'x', 'd2']);
      expect(rows.map((r) => r['id']), unorderedEquals(['d0', 'd2']));
      expect(core.requests, ['dose_logs:fetchMany']);
    });

    test('pages continue after an id full of PostgREST syntax, and the '
        'answer cap cuts a page short', () async {
      const odd = ['a"b', 'a,b', 'a)b', 'a.b', r'a\b', 'a(b'];
      await wire.table('medications').insertIfAbsent([
        for (final id in odd) {'id': id, 'user_id': 'u', 'name': id},
      ]);
      core.rowCap = 4;
      final horizon = core.horizon;
      final seen = <String>[];
      PullKey? after;
      for (var i = 0; i < 5; i++) {
        final page = await wire
            .table('medications')
            .page(after: after, horizon: horizon);
        if (i == 0) expect(page, hasLength(4));
        final next = afterPullPage(page, horizon: horizon);
        seen.addAll([for (final r in page) r['id'] as String]);
        after = next.key;
        if (next.done) break;
      }
      expect(seen, [...odd]..sort());
    });

    test('an insert names its columns; a key a row leaves out is stored '
        'null, as PostgREST does without missing=default', () async {
      await wire.table('medications').insertIfAbsent([
        {'id': 'm1', 'user_id': 'u', 'name': 'One', 'quantity': 3},
      ]);
      await wire.client().from('medications').upsert([
        {'id': 'm2', 'user_id': 'u', 'name': 'Two'},
        {'id': 'm3', 'user_id': 'u', 'name': 'Three', 'notes': 'n'},
      ], ignoreDuplicates: true);
      expect(wire.log.last, contains('columns=%22id%22%2C%22user_id%22'));
      expect(core.rowsOf('medications')['m2']!['notes'], isNull);
      expect(core.rowsOf('medications')['m3']!['notes'], 'n');
      // An id the server has is left alone.
      await wire.table('medications').insertIfAbsent([
        {'id': 'm1', 'user_id': 'u', 'name': 'Changed', 'quantity': 9},
      ]);
      expect(core.rowsOf('medications')['m1']!['name'], 'One');
    });

    test('any other request shape is refused', () async {
      await seedSchedule();
      final client = wire.client();
      for (final request in <Future<Object?> Function()>[
        () => client.from('medications').delete().eq('id', 'm1'),
        () => client.from('medications').update({'name': 'x'}).eq('name', 'y'),
        () => client.from('medications').insert({'id': 'm9', 'name': 'x'}),
        () => client.from('medications').select('name'),
        () => client.from('medications').select().like('name', 'I%'),
      ]) {
        await expectLater(request(), throwsA(isA<PostgrestException>()));
      }
      expect(core.rowsOf('medications').keys, ['m1']);
    });

    test('a project without the migration: the state and the wipe answer '
        'PGRST202; "delete all data" falls back and is refused', () async {
      await seedSchedule();
      wire.migrated = false;
      await expectLater(
        wire.state.read(),
        throwsA(isA<MissingMigrationException>()),
      );
      // The fallback deletes table by table, which the fake refuses: a
      // project without the migration is not what it models.
      await expectLater(
        wire.accountData.deleteAllData(),
        throwsA(isA<PostgrestException>()),
      );
      wire.migrated = true;
      await wire.accountData.deleteAllData();
      expect(core.rowsOf('medications'), isEmpty);
      expect((await wire.state.read()).wipeGeneration, 1);
    });
  });

  group('the fakes over HTTP', () {
    test('go through the app\'s PostgREST datasources and keep their failure '
        'knobs', () async {
      final server = FakeServer(() => now, transport: FakeTransport.http);
      final log = FakePostgrest.of(server.core).log;
      await server.meds.rows.insertIfAbsent([
        {'id': 'm1', 'user_id': 'u', 'name': 'One'},
      ]);
      expect(log.single, startsWith('POST /rest/v1/medications?'));
      server.meds.rows.failIds.add('m1');
      await expectLater(
        server.meds.rows.patch('m1', {'name': 'x'}),
        throwsStateError,
      );
      server.meds.rows.failIds.clear();
      server.meds.rows.loseAnswerFor.add('m1');
      await expectLater(
        server.meds.rows.patch('m1', {'name': 'Two', 'write_id': 'w'}),
        throwsA(anything),
      );
      expect(server.core.rowsOf('medications')['m1']!['name'], 'Two');
      server.state.migrated = false;
      await expectLater(
        server.state.read(),
        throwsA(
          isA<MissingMigrationException>().having(
            (e) => e.cause,
            'cause',
            isA<PostgrestException>().having((c) => c.code, 'code', 'PGRST202'),
          ),
        ),
      );
      expect(log.last, 'POST /rest/v1/rpc/medora_sync_state?');
      expect(syncV2Migration, contains('20260918000000_sync_v2.sql'));
    });

    test('by default only with MEDORA_FAKE_TRANSPORT=http', () {
      expect(
        defaultFakeTransport,
        const String.fromEnvironment('MEDORA_FAKE_TRANSPORT') == 'http'
            ? FakeTransport.http
            : FakeTransport.dart,
      );
      final server = FakeServer(() => now);
      expect(
        server.meds.rows.wire != null,
        defaultFakeTransport == FakeTransport.http,
      );
    });
  });
}
