/// The year of doses (`year_of_doses.dart`) against a local Supabase: the
/// same steps, and the same number of requests, as over the fake PostgREST
/// (`test/services/year_of_doses_http_test.dart`). Skipped without the
/// dart-defines (see `local_supabase.dart`).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';

import '../helpers/test_database.dart';
import 'local_supabase.dart';
import 'year_of_doses.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test(
    'a year on two devices costs as many requests as over the fake',
    () async {
      final log = RequestLog(http.Client());
      final acct = await signUp(httpClient: log);
      final dir = await Directory.systemTemp.createTemp('medora_it_year_');
      addTearDown(() => dir.delete(recursive: true));
      final client = acct.client;
      final steps = await runYearOfDoses(
        remotes: (
          medications: MedicationRemoteDatasource(client),
          treatments: TreatmentRemoteDatasource(client),
          prescriptions: PrescriptionRemoteDatasource(client),
          doses: DoseLogRemoteDatasource(client),
          families: FamilyRemoteDatasource(client),
          state: SyncStateRemoteDatasource(client),
        ),
        userId: acct.userId,
        requests: () => syncRequests(log.requests),
        dir: dir,
      );
      // ignore: avoid_print
      print(formatSteps('Requests against the local Supabase:', steps));
      final server = await client.from('dose_logs').count();
      expect(server, 4380);
      expect(yearOfDosesCost(steps), yearOfDosesExpectedCost);
    },
    skip: localSupabaseConfigured ? false : localSupabaseSkip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
