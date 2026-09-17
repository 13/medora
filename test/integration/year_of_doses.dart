/// A realistic year on two devices of one account, and what it costs in
/// requests: three prescriptions taken twice a day for a year (2,190
/// doses), a second device's first sync, a sweep of the overdue doses on
/// both devices, a sign-in that marks every row for upload, and a device
/// with a year of local-only data that signs in for the first time.
///
/// The same steps run against a local Supabase
/// (`sync_request_cost_test.dart`) and against the fake PostgREST
/// (`test/services/year_of_doses_http_test.dart`), counted the same way:
/// every request to `/rest/v1/` except the family tables.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/seed.dart';

/// An HTTP client that records every PostgREST request it sends, as
/// `METHOD /rest/v1/table?query`.
class RequestLog extends http.BaseClient {
  RequestLog(this._inner);

  final http.Client _inner;
  final List<String> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.startsWith('/rest/v1/')) {
      requests.add(
        '${request.method} ${request.url.path}?${request.url.query}',
      );
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// The requests of [log] a sync of the four synced tables makes: every
/// PostgREST request except the family tables, which sync v2 left alone.
int syncRequests(Iterable<String> log) => log
    .where((r) => !r.contains('/rest/v1/families') && !r.contains('/family_'))
    .length;

/// The server side of one account.
typedef YearRemotes = ({
  MedicationRemoteDatasource medications,
  TreatmentRemoteDatasource treatments,
  PrescriptionRemoteDatasource prescriptions,
  DoseLogRemoteDatasource doses,
  FamilyRemoteDatasource families,
  SyncStateRemoteDatasource state,
});

class YearDevice {
  YearDevice(this.name, this.path, this.remotes, {required this.userId}) {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: remotes.medications,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: remotes.treatments,
      prescriptionLocal: prescriptionLocal,
      prescriptionRemote: remotes.prescriptions,
      doseLogLocal: doseLogLocal,
      doseLogRemote: remotes.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: remotes.families,
      syncState: remotes.state,
      isOnline: () => online,
      currentUserId: () => userId,
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
      capRetryDelay: const Duration(days: 1),
      onPrescriptionsPulled: (pulled) => schedule.applyPulled(pulled),
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: doseLogLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
    );
    schedule = DoseScheduleService(
      prescriptions: PrescriptionRepositoryImpl(
        localDatasource: prescriptionLocal,
      ),
      doses: doses,
    );
  }

  final String name;
  final String path;
  final YearRemotes remotes;
  final String userId;
  bool online = true;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  final prescriptionLocal = PrescriptionLocalDatasource();
  final doseLogLocal = DoseLogLocalDatasource();
  late final SyncService service;
  late final DoseLogRepositoryImpl doses;
  late final DoseScheduleService schedule;
  final List<Future<void>> _requests = [];

  /// Every cycle this device ran, with its report.
  final List<SyncReport> reports = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll().then((r) {
      if (r != null) reports.add(r);
    });
    _requests.add(cycle);
    return cycle;
  }

  /// Opens this device's database, runs [body], and waits for every sync
  /// the body asked for.
  Future<T> run<T>(Future<T> Function(Database db) body) async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = path;
    final result = await body(await AppDatabase.instance.database);
    await pumpEventQueue();
    while (_requests.isNotEmpty) {
      final pending = List.of(_requests);
      _requests.clear();
      await Future.wait(pending);
      await pumpEventQueue();
    }
    return result;
  }

  Future<void> sync() => run((_) => _cycle());

  Future<void> _cycle() async {
    final report = await service.syncAll();
    if (report != null) reports.add(report);
  }

  Future<int> count(String where) => run(
    (db) async =>
        (await db.rawQuery(
              'SELECT COUNT(*) AS n FROM dose_logs WHERE $where',
            )).first['n']!
            as int,
  );

  /// Three prescriptions, twice a day for a year that started half a year
  /// ago, each made and pushed in turn.
  Future<void> createYear({required DateTime today}) async {
    for (var i = 0; i < 3; i++) {
      await run((db) async {
        final seeded = await seedPrescription(
          db,
          startTime: DateTime(today.year, today.month, today.day - 180, 8),
          durationDays: 365,
          scheduleType: 'times_per_day',
        );
        await db.update(
          'prescriptions',
          {
            'schedule_times': '["08:00","20:00"]',
            'sync_status': SyncStatus.pendingCreate,
          },
          where: 'id = ?',
          whereArgs: [seeded.prescriptionId],
        );
        for (final (table, id) in [
          ('medications', seeded.medicationId),
          ('treatments', seeded.treatmentId),
        ]) {
          await db.update(
            table,
            {'sync_status': SyncStatus.pendingCreate},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        await doses.generateDoseLogsForPrescription(seeded.prescriptionId);
        await _cycle();
      });
    }
  }

  /// A sign-in: every row is marked for upload, then a cycle.
  Future<void> signIn() => run((_) async {
    final prefs = await SharedPreferences.getInstance();
    await LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: cursors,
      prefs: prefs,
    ).markAllForUpload(userId);
    await _cycle();
  });

  void dispose() => service.dispose();
}

/// One measured step: its name and the requests it cost.
typedef YearStep = ({String step, int requests});

/// Runs the year on devices A and B, then on a third device C that signs
/// in with a year of local-only data, all against [remotes]. [requests]
/// reads the number of requests sent so far. Returns every step's cost.
/// Every cycle must end clean and every device must end with nothing
/// pending.
Future<List<YearStep>> runYearOfDoses({
  required YearRemotes remotes,
  required String userId,
  required int Function() requests,
  required Directory dir,
}) async {
  SharedPreferences.setMockInitialValues({});
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final steps = <YearStep>[];
  Future<void> measure(String step, Future<void> Function() body) async {
    final before = requests();
    await body();
    steps.add((step: step, requests: requests() - before));
  }

  final a = YearDevice('A', '${dir.path}/a.db', remotes, userId: userId);
  final b = YearDevice('B', '${dir.path}/b.db', remotes, userId: userId);
  final c = YearDevice('C', '${dir.path}/c.db', remotes, userId: userId);
  try {
    await measure(
      'A creates 3 prescriptions (a year, twice a day) and pushes',
      () => a.createYear(today: today),
    );
    await measure('B first sync', b.sync);
    await measure('A quiet cycle', a.sync);
    await measure('A sweeps the overdue doses, and its cycle', () async {
      await a.run((_) => a.doses.markOverduePendingAsMissed(DateTime.now()));
      await a.sync();
    });
    await measure('B sweeps the same doses offline, then syncs', () async {
      b.online = false;
      await b.run((_) => b.doses.markOverduePendingAsMissed(DateTime.now()));
      b.online = true;
      await b.sync();
    });
    await measure('A quiet cycle', a.sync);
    await measure('B quiet cycle', b.sync);
    await measure('A signs in again, then a cycle', a.signIn);
    await measure('A quiet cycle', a.sync);

    // C made a year offline, never synced, then signs in.
    c.online = false;
    await c.createYear(today: today);
    await c.run((db) async {
      for (final t in [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        await db.update(t, {'sync_status': SyncStatus.synced});
      }
    });
    c.online = true;
    await measure('C (a year of local data) signs in first', c.signIn);
    await measure('C cycle after', c.sync);

    for (final d in [a, b, c]) {
      for (final r in d.reports) {
        expect(
          r.isClean,
          isTrue,
          reason: '${d.name}: ${r.fatal} ${r.failures}',
        );
      }
      expect(
        await d.count("sync_status != 'synced'"),
        0,
        reason: '${d.name} has doses waiting',
      );
    }
    expect(await a.count("status = 'missed'"), greaterThan(1000));
    expect(
      await b.count("status = 'missed'"),
      await a.count("status = 'missed'"),
    );
    expect(await a.count('1 = 1'), 2190);
    // C holds its own year and A's.
    expect(await c.count('1 = 1'), 4380);
  } finally {
    a.dispose();
    b.dispose();
    c.dispose();
  }
  return steps;
}

/// [steps] as a table for the test output.
String formatSteps(String title, List<YearStep> steps) => [
  title,
  for (final s in steps)
    '  ${s.step.padRight(62)} ${s.requests.toString().padLeft(5)}',
].join('\n');

/// [steps] as `step: requests` lines, for comparing two runs.
List<String> yearOfDosesCost(List<YearStep> steps) => [
  for (final s in steps) '${s.step}: ${s.requests}',
];

/// What [runYearOfDoses] costs, request by request, against the fake
/// PostgREST and against a local Supabase alike.
const yearOfDosesExpectedCost = [
  'A creates 3 prescriptions (a year, twice a day) and pushes: 108',
  'B first sync: 11',
  'A quiet cycle: 5',
  'A sweeps the overdue doses, and its cycle: 23',
  'B sweeps the same doses offline, then syncs: 29',
  'A quiet cycle: 5',
  'B quiet cycle: 5',
  'A signs in again, then a cycle: 36',
  'A quiet cycle: 5',
  'C (a year of local data) signs in first: 98',
  'C cycle after: 11',
];
