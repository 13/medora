/// What the four pushing upserts make of the server's answer. The sync cycle
/// marks a pushed row synced on the strength of that answer, so an answer
/// without the written row must be an error, never a silent "no stamp".
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A PostgREST answer to a single-object request that matched no row. With
/// this wording, `maybeSingle()` turns it into null.
http.Response _noRow(http.Request request) => http.Response(
  jsonEncode({
    'code': 'PGRST116',
    'details': 'Results contain 0 rows',
    'hint': null,
    'message': 'JSON object requested, multiple (or no) rows returned',
  }),
  406,
  reasonPhrase: 'Results contain 0 rows',
  headers: {'content-type': 'application/json; charset=utf-8'},
  request: request,
);

http.Response _written(http.Request request, String stamp) => http.Response(
  jsonEncode({'updated_at': stamp}),
  201,
  headers: {'content-type': 'application/vnd.pgrst.object+json'},
  request: request,
);

void main() {
  final pushes = <String, Future<DateTime?> Function(SupabaseClient client)>{
    'medications': (c) => MedicationRemoteDatasource(
      c,
    ).upsertMedication(const MedicationModel(id: 'm1', name: 'M', quantity: 1)),
    'treatments': (c) => TreatmentRemoteDatasource(c).upsertTreatment(
      TreatmentModel(id: 't1', name: 'T', startDate: DateTime(2026, 3, 2)),
    ),
    'prescriptions': (c) => PrescriptionRemoteDatasource(c).upsertPrescription(
      PrescriptionModel(
        id: 'p1',
        treatmentId: 't1',
        medicationId: 'm1',
        dosage: '1',
        startTime: DateTime(2026, 3, 2, 8),
      ),
    ),
    'dose_logs': (c) => DoseLogRemoteDatasource(c).upsertDoseLog(
      DoseLogModel(
        id: 'd1',
        prescriptionId: 'p1',
        scheduledTime: DateTime(2026, 3, 2, 8),
      ),
    ),
  };

  SupabaseClient clientAnswering(
    http.Response Function(http.Request request) answer,
  ) {
    final client = SupabaseClient(
      'http://supabase.test',
      'anon-key',
      httpClient: MockClient((request) async => answer(request)),
    );
    addTearDown(client.dispose);
    return client;
  }

  for (final MapEntry(key: table, value: push) in pushes.entries) {
    group(table, () {
      test('an upsert answered without its row fails', () async {
        await expectLater(
          push(clientAnswering(_noRow)),
          throwsA(isA<PostgrestException>()),
        );
      });

      test(
        'an upsert answered with its row returns the server stamp',
        () async {
          final stamp = await push(
            clientAnswering(
              (r) => _written(r, '2026-03-04T12:00:00.123456+00:00'),
            ),
          );
          expect(stamp, DateTime.utc(2026, 3, 4, 12, 0, 0, 123, 456));
        },
      );
    });
  }

  group('dose logs created on this device', () {
    DoseLogModel dose(String id) => DoseLogModel(
      id: id,
      prescriptionId: 'p1',
      scheduledTime: DateTime.utc(2026, 3, 2, 8),
      updatedAt: DateTime.utc(1970),
    );

    test('go out as one insert that leaves existing rows alone', () async {
      final requests = <http.Request>[];
      final client = clientAnswering((request) {
        requests.add(request);
        return http.Response('', 201, request: request);
      });

      await DoseLogRemoteDatasource(
        client,
      ).insertDoseLogsIfAbsent([dose('d1'), dose('d2')]);

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/dose_logs');
      expect(request.url.queryParameters['on_conflict'], 'id');
      expect(
        request.headers['Prefer'],
        contains('resolution=ignore-duplicates'),
      );
      final body = jsonDecode(request.body) as List<dynamic>;
      expect(body.map((r) => (r as Map)['id']), ['d1', 'd2']);
      expect((body.first as Map)['updated_at'], '1970-01-01T00:00:00.000Z');
    });

    test('an empty list sends nothing', () async {
      var calls = 0;
      final client = clientAnswering((request) {
        calls++;
        return http.Response('', 201, request: request);
      });
      final remote = DoseLogRemoteDatasource(client);
      await remote.insertDoseLogsIfAbsent(const []);
      expect(await remote.getDoseLogsByIds(const []), isEmpty);
      expect(calls, 0);
    });

    test('are read back by id, tombstones included', () async {
      final requests = <http.Request>[];
      final client = clientAnswering((request) {
        requests.add(request);
        return http.Response(
          jsonEncode([
            {
              'id': 'd1',
              'prescription_id': 'p1',
              'scheduled_time': '2026-03-02T08:00:00Z',
              'status': 'taken',
              'updated_at': '2026-03-02T08:05:00Z',
            },
            {
              'id': 'd2',
              'prescription_id': 'p1',
              'scheduled_time': '2026-03-02T16:00:00Z',
              'status': 'pending',
              'updated_at': '2026-03-02T08:06:00Z',
              'deleted_at': '2026-03-02T08:06:00Z',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final rows = await DoseLogRemoteDatasource(
        client,
      ).getDoseLogsByIds(['d1', 'd2']);

      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.queryParameters['id'], 'in.("d1","d2")');
      expect(request.url.queryParameters.containsKey('deleted_at'), isFalse);
      expect(rows.map((d) => d.status.name), ['taken', 'pending']);
      expect(rows.last.deletedAt, isNotNull);
    });
  });
}
