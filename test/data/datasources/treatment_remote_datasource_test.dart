/// Review I-2: a Supabase project without the sick-leave columns must fail a
/// treatment push with a message that names the migration to apply, as a
/// medication push already does, not with a bare PostgREST code.
///
/// The real datasource runs against an HTTP stub; no Supabase project is
/// contacted.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A client whose every request is answered by [answer], with the
/// request attached (PostgREST's client reads the method off it).
SupabaseClient stubClient(http.Response Function() answer) {
  final client = SupabaseClient(
    'http://supabase.invalid',
    'anon-key',
    httpClient: MockClient((request) async {
      final a = answer();
      return http.Response(
        a.body,
        a.statusCode,
        headers: a.headers,
        request: request,
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return client;
}

/// PostgREST's answer when a payload key is not in its schema cache.
http.Response missingColumnAnswer(String column) => http.Response(
  jsonEncode({
    'code': 'PGRST204',
    'details': null,
    'hint': null,
    'message':
        "Could not find the '$column' column of 'treatments' in the schema "
        'cache',
  }),
  400,
  headers: {'content-type': 'application/json'},
);

final treatment = TreatmentModel(
  id: 't1',
  userId: 'user-a',
  name: 'Flu',
  startDate: DateTime(2026, 3, 2),
);

void main() {
  test('a push to a project without the sick-leave columns names the '
      'column and the migration', () async {
    final remote = TreatmentRemoteDatasource(
      stubClient(() => missingColumnAnswer('doctor')),
    );

    await expectLater(
      remote.rows.insertIfAbsent([treatment.toJson()]),
      throwsA(
        isA<MissingColumnException>()
            .having((e) => e.table, 'table', 'treatments')
            .having((e) => e.column, 'column', 'doctor')
            .having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('treatments.doctor'),
                contains(
                  'supabase/migrations/20260917000000_treatment_sick_leave.sql',
                ),
              ),
            ),
      ),
    );
  });

  test('any other rejection passes through untouched', () async {
    final remote = TreatmentRemoteDatasource(
      stubClient(
        () => http.Response(
          jsonEncode({
            'code': '42501',
            'message': 'new row violates row-level security policy',
          }),
          403,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      remote.rows.insertIfAbsent([treatment.toJson()]),
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '42501')),
    );
  });

  test('an update to such a project names the migration too', () async {
    final remote = TreatmentRemoteDatasource(
      stubClient(() => missingColumnAnswer('sick_leave_ref')),
    );

    await expectLater(
      remote.rows.patch('t1', {'sick_leave_ref': 'A'}, ifVersion: 2),
      throwsA(
        isA<MissingColumnException>().having(
          (e) => e.column,
          'column',
          'sick_leave_ref',
        ),
      ),
    );
  });
}
