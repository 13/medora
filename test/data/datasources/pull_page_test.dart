/// The delta pull asks each table for one page at a time, oldest first with
/// the id as tiebreak, starting after the last row it already has. A hosted
/// Supabase project answers at most 1000 rows per request, so a pull that
/// asked for everything (or newest first) lost the rest without a sign.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/pull_page.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef _Pull =
    Future<List<Object>> Function(
      SupabaseClient client,
      DateTime? since,
      PullKey? after,
    );

void main() {
  final pulls = <String, _Pull>{
    'medications': (c, since, after) =>
        MedicationRemoteDatasource(c).getMedicationsSince(since, after: after),
    'treatments': (c, since, after) =>
        TreatmentRemoteDatasource(c).getTreatmentsSince(since, after: after),
    'prescriptions': (c, since, after) => PrescriptionRemoteDatasource(
      c,
    ).getPrescriptionsSince(since, after: after),
    'dose_logs': (c, since, after) =>
        DoseLogRemoteDatasource(c).getDoseLogsSince(since, after: after),
  };

  /// The query parameters of the one request [pull] makes.
  Future<Map<String, List<String>>> queryOf(
    _Pull pull,
    DateTime? since,
    PullKey? after,
  ) async {
    final urls = <Uri>[];
    final client = SupabaseClient(
      'http://supabase.test',
      'anon-key',
      httpClient: MockClient((request) async {
        urls.add(request.url);
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    await pull(client, since, after);
    return urls.single.queryParametersAll;
  }

  for (final MapEntry(key: table, value: pull) in pulls.entries) {
    group(table, () {
      test('a first page asks for the oldest rows, id as tiebreak, at most '
          '$pullPageSize', () async {
        final query = await queryOf(pull, null, null);

        expect(query['order'], ['updated_at.asc.nullslast,id.asc.nullslast']);
        expect(query['limit'], ['$pullPageSize']);
        expect(query.containsKey('updated_at'), isFalse);
        expect(query.containsKey('or'), isFalse);
      });

      test('a later page starts after the last row it has', () async {
        final since = DateTime.utc(2026, 3, 4, 12);
        final after = PullKey(
          DateTime.utc(2026, 3, 4, 12, 30, 5, 123, 456),
          '0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1',
        );

        final query = await queryOf(pull, since, after);

        expect(query['updated_at'], ['gt.2026-03-04T12:00:00.000Z']);
        expect(query['or'], [
          '(updated_at.gt."2026-03-04T12:30:05.123456Z",'
              'and(updated_at.eq."2026-03-04T12:30:05.123456Z",'
              'id.gt."0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1"))',
        ]);
        expect(query['order'], ['updated_at.asc.nullslast,id.asc.nullslast']);
        expect(query['limit'], ['$pullPageSize']);
      });
    });
  }

  test('a quote or backslash in an id cannot end the filter value', () async {
    final after = PullKey(DateTime.utc(2026), r'a"b\c');

    final query = await queryOf(pulls['medications']!, null, after);

    expect(query['or']!.single, contains(r'id.gt."a\"b\\c"'));
  });
}
