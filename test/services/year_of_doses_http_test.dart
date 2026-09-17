/// The year of doses (`test/integration/year_of_doses.dart`) through the
/// app's real PostgREST datasources and the fake PostgREST, whatever
/// transport the rest of the suite uses. The same steps run against a
/// local Supabase in `test/integration/sync_request_cost_test.dart`; the
/// two must cost the same number of requests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_postgrest.dart';
import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';
import '../integration/year_of_doses.dart';

void main() {
  late Directory dir;

  setUp(() async {
    await setUpTestDatabase();
    dir = Directory.systemTemp.createTempSync('medora_year_');
  });

  tearDown(() async {
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  test(
    'a year on two devices costs a few requests per step over HTTP',
    () async {
      final server = FakeServer(
        () => DateTime.now().toUtc(),
        transport: FakeTransport.http,
      );
      final wire = FakePostgrest.of(server.core);
      final steps = await runYearOfDoses(
        remotes: (
          medications: server.meds,
          treatments: server.treatments,
          prescriptions: server.prescriptions,
          doses: server.doses,
          families: server.families,
          state: server.state,
        ),
        userId: 'user-a',
        requests: () => syncRequests(wire.log),
        dir: dir,
      );
      // ignore: avoid_print
      print(formatSteps('Requests over the fake PostgREST:', steps));
      expect(yearOfDosesCost(steps), yearOfDosesExpectedCost);
      expect(server.core.rowsOf('dose_logs'), hasLength(4380));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
