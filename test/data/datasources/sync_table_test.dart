/// The requests the sync v2 datasources send, read off a stub HTTP client:
/// no network, no real project.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.Request> seen;

  SupabaseClient answering(Object? body, {int status = 200}) {
    seen = [];
    final client = SupabaseClient(
      'http://supabase.test',
      'anon-key',
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode(body),
          status,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    return client;
  }

  String sent(int i) => Uri.decodeComponent(seen[i].url.toString());

  const doseSelect = 'select=*,prescriptions(id,medications(name))';
  const order = 'order=sync_xid.asc.nullslast,id.asc.nullslast&limit=1000';

  group('PostgrestSyncTable', () {
    PostgrestSyncTable doses(SupabaseClient c) => PostgrestSyncTable(
      c,
      'dose_logs',
      select: '*, prescriptions(id, medications(name))',
    );

    test('a first page asks for everything below the horizon', () async {
      await doses(answering([])).page(after: null, horizon: 900);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect'
        '&sync_xid=lt.900&$order',
      );
    });

    test('a page after a finished pull starts at the stored horizon', () async {
      await doses(answering([])).page(after: const PullKey(812), horizon: 900);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect'
        '&sync_xid=lt.900&sync_xid=gte.812&$order',
      );
    });

    test(
      'a later page continues after its last row; the id is quoted',
      () async {
        await doses(
          answering([]),
        ).page(after: const PullKey(812, 'a"b'), horizon: 900);
        expect(
          sent(0),
          'http://supabase.test/rest/v1/dose_logs?$doseSelect&sync_xid=lt.900'
          r'&or=(sync_xid.gt.812,and(sync_xid.eq.812,id.gt."a\"b"))'
          '&$order',
        );
      },
    );

    test(
      'a conditional update names the version and asks for the row',
      () async {
        final row = await doses(
          answering([
            {'id': 'd1', 'row_version': 4},
          ]),
        ).patch('d1', {'status': 'taken'}, ifVersion: 3);
        expect(seen.single.method, 'PATCH');
        expect(
          sent(0),
          'http://supabase.test/rest/v1/dose_logs?id=eq.d1&row_version=eq.3'
          '&$doseSelect',
        );
        expect(seen.single.headers['Prefer'], 'return=representation');
        expect(jsonDecode(seen.single.body), {'status': 'taken'});
        expect(row, {'id': 'd1', 'row_version': 4});
      },
    );

    test('a bulk update names every id and each condition in one request, '
        'and answers the rows it wrote', () async {
      final rows =
          await doses(
            answering([
              {'id': 'd2', 'row_version': 2},
            ]),
          ).patchMany(
            ['d1', 'd2'],
            {'status': 'missed'},
            ifVersion: 1,
            ifStatus: 'pending',
            ifLive: true,
          );
      expect(seen.single.method, 'PATCH');
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?id=in.("d1","d2")'
        '&row_version=eq.1&status=eq.pending&deleted_at=is.null&$doseSelect',
      );
      expect(seen.single.headers['Prefer'], 'return=representation');
      expect(jsonDecode(seen.single.body), {'status': 'missed'});
      expect(rows, [
        {'id': 'd2', 'row_version': 2},
      ]);
      // Nothing to write: no request.
      expect(
        await doses(answering([])).patchMany([], {'status': 'x'}),
        isEmpty,
      );
      expect(seen, isEmpty);
    });

    test('a conditional update that matched nothing answers null', () async {
      expect(
        await doses(
          answering([]),
        ).patch('d1', {'status': 'taken'}, ifVersion: 3),
        isNull,
      );
    });

    test('a guarded delete filters on the status and on being live', () async {
      await doses(answering([])).patch(
        'd1',
        {'deleted_at': '2026-03-05T12:00:00.000Z'},
        ifStatus: 'pending',
        ifLive: true,
      );
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?id=eq.d1&status=eq.pending'
        '&deleted_at=is.null&$doseSelect',
      );
    });

    test('an insert leaves existing ids alone', () async {
      await doses(answering(null, status: 201)).insertIfAbsent([
        {'id': 'd1'},
      ]);
      expect(seen.single.method, 'POST');
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?on_conflict=id&columns="id"',
      );
      expect(seen.single.headers['Prefer'], 'resolution=ignore-duplicates');
    });

    test('fetch and fetchMany read by id', () async {
      final table = doses(answering([]));
      await table.fetch('d1');
      await table.fetchMany(['d1', 'd2']);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect&id=eq.d1',
      );
      expect(
        sent(1),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect&id=in.("d1","d2")',
      );
    });

    test('a write to a project without a column names the migration', () async {
      final table = PostgrestSyncTable(
        answering({
          'code': 'PGRST204',
          'message': "Could not find the 'doctor' column of 'treatments'",
        }, status: 400),
        'treatments',
        migration: 'supabase/migrations/x.sql',
        fallbackColumn: 'sick_leave_from',
      );
      await expectLater(
        table.patch('t1', {'doctor': 'Dr. Rossi'}, ifVersion: 1),
        throwsA(
          isA<MissingColumnException>()
              .having((e) => e.column, 'column', 'doctor')
              .having(
                (e) => e.migration,
                'migration',
                'supabase/migrations/x.sql',
              ),
        ),
      );
    });
  });

  test('a write to a project without a sync v2 column names the sync v2 '
      'migration', () async {
    final table = PostgrestSyncTable(
      answering({
        'code': 'PGRST204',
        'message': "Could not find the 'write_id' column of 'medications'",
      }, status: 400),
      'medications',
      migration: 'supabase/migrations/20260916000000_medication_ean.sql',
      fallbackColumn: 'ean',
    );
    await expectLater(
      table.patch('m1', {'name': 'x', 'write_id': 'w1'}, ifVersion: 1),
      throwsA(
        isA<MissingColumnException>()
            .having((e) => e.column, 'column', 'write_id')
            .having((e) => e.migration, 'migration', syncV2Migration),
      ),
    );
  });

  test(
    'a project without the edit-time map names the sync v2 migration',
    () async {
      final table = PostgrestSyncTable(
        answering({
          'code': 'PGRST204',
          'message':
              "Could not find the 'field_edited_at' column of 'treatments'",
        }, status: 400),
        'treatments',
      );
      await expectLater(
        table.patch('t1', {
          'notes': 'x',
          'field_edited_at': <String, Object?>{},
        }, ifVersion: 1),
        throwsA(
          isA<MissingColumnException>()
              .having((e) => e.column, 'column', 'field_edited_at')
              .having((e) => e.migration, 'migration', syncV2Migration),
        ),
      );
    },
  );

  group('afterPullPage', () {
    Map<String, dynamic> row(int xid, String id) => {'id': id, 'sync_xid': xid};

    test('only an empty page ends a table, at the horizon', () {
      final end = afterPullPage(const [], horizon: 900);
      expect(end.done, isTrue);
      expect(end.key, const PullKey(900));
    });

    test('a short page is not the end: the project may cap its answers '
        'below $pullPageSize rows', () {
      final step = afterPullPage([row(5, 'a'), row(7, 'b')], horizon: 900);
      expect(step.done, isFalse);
      expect(step.key, const PullKey(7, 'b'));
    });

    test('a full page continues after its last row', () {
      final rows = [for (var i = 0; i < pullPageSize; i++) row(i, 'r$i')];
      final step = afterPullPage(rows, horizon: 5000);
      expect(step.done, isFalse);
      expect(step.key, const PullKey(pullPageSize - 1, 'r999'));
    });
  });

  group('stockAfter', () {
    test('brings the change into range, then caps the quantity', () {
      expect(stockAfter(10, delta: -3), 7);
      expect(stockAfter(10, delta: -100), 0);
      expect(stockAfter(3, setTo: -1), 0);
      expect(stockAfter(3, setTo: 1000000), maxStock);
      expect(stockAfter(5, delta: 1000000), maxStock);
      expect(stockAfter(-5, delta: 3), 0);
      expect(
        stockAfter(2000000, delta: -2000000),
        maxStock,
        reason: 'the delta counts as -999999 first',
      );
      expect(stockAfter(0, delta: 1 << 40), maxStock);
    });
  });

  group('RemoteMeta', () {
    test('reads the bookkeeping of a row', () {
      final meta = RemoteMeta.fromJson({
        'sync_xid': 812,
        'row_version': 3,
        'write_id': 'w1',
        'edited_at': '2026-03-05T09:00:00+00:00',
        'updated_at': '2026-03-05T09:00:01+00:00',
      });
      expect(meta.syncXid, 812);
      expect(meta.rowVersion, 3);
      expect(meta.writeId, 'w1');
      expect(meta.editedAt, DateTime.utc(2026, 3, 5, 9));
      expect(meta.effectiveEditedAt, DateTime.utc(2026, 3, 5, 9));
    });

    test('a row from before the migration falls back to updated_at', () {
      final meta = RemoteMeta.fromJson({
        'sync_xid': 0,
        'row_version': 1,
        'updated_at': '2026-01-01T00:00:00+00:00',
      });
      expect(meta.editedAt, isNull);
      expect(meta.effectiveEditedAt, DateTime.utc(2026));
    });
  });

  group('PullKey', () {
    test('round-trips through storage', () {
      expect(
        PullKey.fromStorage(const PullKey(812, 'a|b').toStorage()),
        const PullKey(812, 'a|b'),
      );
      expect(
        PullKey.fromStorage(const PullKey(900).toStorage()),
        const PullKey(900),
      );
      expect(PullKey.fromStorage('2026-03-05T09:00:00.000Z'), isNull);
      expect(PullKey.fromStorage(null), isNull);
    });
  });

  group('SyncStateRemoteDatasource', () {
    test('reads the horizon', () async {
      final state = await SyncStateRemoteDatasource(
        answering({'schema': 2, 'horizon': 4711}),
      ).read();
      expect(state.schema, 2);
      expect(state.horizon, 4711);
      expect(seen.single.method, 'POST');
      expect(sent(0), 'http://supabase.test/rest/v1/rpc/medora_sync_state');
    });

    for (final code in ['PGRST202', '42883']) {
      test('a missing function ($code) names the migration', () async {
        await expectLater(
          SyncStateRemoteDatasource(
            answering({
              'code': code,
              'message': 'no such function',
            }, status: 404),
          ).read(),
          throwsA(
            isA<MissingMigrationException>()
                .having((e) => e.migration, 'migration', syncV2Migration)
                .having(
                  (e) => '$e',
                  'text',
                  contains('supabase/migrations/20260918000000_sync_v2.sql'),
                ),
          ),
        );
      });
    }

    test('an older schema is a missing migration too', () async {
      await expectLater(
        SyncStateRemoteDatasource(
          answering({'schema': 1, 'horizon': 5}),
        ).read(),
        throwsA(isA<MissingMigrationException>()),
      );
    });

    test('any other error passes through', () async {
      await expectLater(
        SyncStateRemoteDatasource(
          answering({'code': '500', 'message': 'boom'}, status: 500),
        ).read(),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('PostgrestStockRemote', () {
    test('sends one change and reads the answer', () async {
      final result =
          await PostgrestStockRemote(
            answering({'status': 'applied', 'quantity': 3, 'row_version': 2}),
          ).apply(
            StockOp(
              opId: 'op1',
              medicationId: 'm1',
              delta: -1,
              createdAt: DateTime.utc(2026),
            ),
          );
      expect(sent(0), 'http://supabase.test/rest/v1/rpc/apply_stock_change');
      expect(jsonDecode(seen.single.body), {
        'p_op_id': 'op1',
        'p_medication_id': 'm1',
        'p_delta': -1,
        'p_set_to': null,
      });
      expect(result.status, StockChangeStatus.applied);
      expect(result.quantity, 3);
      expect(result.rowVersion, 2);
    });

    test('sends values out of range brought into range, so the server '
        'never refuses them', () async {
      final client = answering({'status': 'applied', 'quantity': 0});
      final remote = PostgrestStockRemote(client);
      StockOp op({int? delta, int? setTo}) => StockOp(
        opId: 'op1',
        medicationId: 'm1',
        delta: delta,
        setTo: setTo,
        createdAt: DateTime.utc(2026),
      );
      await remote.apply(op(delta: 1 << 40));
      await remote.apply(op(delta: -5000000));
      await remote.apply(op(setTo: 1000000));
      await remote.apply(op(setTo: -1));
      Map<String, dynamic> body(int i) =>
          jsonDecode(seen[i].body) as Map<String, dynamic>;
      expect(body(0)['p_delta'], maxStock);
      expect(body(1)['p_delta'], -maxStock);
      expect(body(2)['p_set_to'], maxStock);
      expect(body(3)['p_set_to'], 0);
      expect(body(3)['p_delta'], isNull);
    });

    test('a medication the server does not have is gone', () async {
      final result = await PostgrestStockRemote(answering({'status': 'gone'}))
          .apply(
            StockOp(
              opId: 'op1',
              medicationId: 'm1',
              setTo: 3,
              createdAt: DateTime.utc(2026),
            ),
          );
      expect(result.status, StockChangeStatus.gone);
      expect(result.quantity, isNull);
    });

    test('an answer it does not know throws, so the change is kept', () async {
      for (final answer in [
        {'status': 'missing'},
        <String, Object?>{},
      ]) {
        await expectLater(
          PostgrestStockRemote(answering(answer)).apply(
            StockOp(
              opId: 'op1',
              medicationId: 'm1',
              delta: -1,
              createdAt: DateTime.utc(2026),
            ),
          ),
          throwsA(anything),
          reason: '$answer',
        );
      }
    });
  });
}
