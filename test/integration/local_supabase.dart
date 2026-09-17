/// A local Supabase (`supabase start`) for the integration tests: fresh
/// accounts, and devices with their own database files.
///
/// The URL and anon key come from the `SUPABASE_URL` and
/// `SUPABASE_ANON_KEY` dart-defines (see `supabase status`); the tests are
/// skipped without them. A URL that is not on this machine is refused: these
/// tests create accounts and delete data.
///
/// Run the folder with `--concurrency=1`: the pull horizon is the oldest
/// open transaction of the whole database, so a test that holds one open
/// holds back what every other test's devices can pull.
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
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');

/// The local stack's database container (`supabase_db_<project id>`), for
/// the tests that hold a transaction open with `psql`; they are skipped
/// without it.
const supabaseDbContainer = String.fromEnvironment('SUPABASE_DB_CONTAINER');

final bool localSupabaseConfigured = _url.isNotEmpty && _key.isNotEmpty;

const localSupabaseSkip =
    'Set SUPABASE_URL and SUPABASE_ANON_KEY dart-defines to run against a '
    'local Supabase';

void _refuseRemote() {
  final host = Uri.parse(_url).host;
  if (!const {'127.0.0.1', 'localhost', '::1'}.contains(host)) {
    throw StateError(
      'SUPABASE_URL must point at a local Supabase (supabase start), '
      'not $host',
    );
  }
}

/// A client with no session.
SupabaseClient anonymousClient() {
  _refuseRemote();
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
  );
  addTearDown(client.dispose);
  return client;
}

/// A new account, signed in; its REST requests go through [httpClient]
/// when given.
Future<({SupabaseClient client, String userId})> signUp({
  http.Client? httpClient,
}) async {
  _refuseRemote();
  // No plugin channels in tests: the PKCE flow needs an async storage that
  // only `Supabase.initialize` provides, and auto-refresh would leave a
  // timer running past the test.
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: httpClient,
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
  );
  addTearDown(client.dispose);
  final res = await client.auth.signUp(
    email: 'it-${const Uuid().v4()}@example.com',
    password: 'password-123',
  );
  expect(
    client.auth.currentSession,
    isNotNull,
    reason: 'local Supabase must auto-confirm sign-ups',
  );
  return (client: client, userId: res.user!.id);
}

/// One device of an account against the local stack: its own database file,
/// cycle, cursors and repositories. Only one device's database is open at a
/// time ([run]); every sync a repository asks for runs before [run]
/// returns.
class LocalDevice {
  LocalDevice(this.name, this.path, this.client, this.userId) {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: MedicationRemoteDatasource(client),
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: TreatmentRemoteDatasource(client),
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: PrescriptionRemoteDatasource(client),
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: DoseLogRemoteDatasource(client),
      familyLocal: FamilyLocalDatasource(),
      familyRemote: FamilyRemoteDatasource(client),
      syncState: SyncStateRemoteDatasource(client),
      cursors: cursors,
      failures: failures,
      isOnline: () => online,
      currentUserId: () => userId,
      onlineStream: const Stream.empty(),
    );
    medications = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      requestSync: _requestSync,
    );
    treatments = TreatmentRepositoryImpl(
      localDatasource: TreatmentLocalDatasource(),
      requestSync: _requestSync,
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: DoseLogLocalDatasource(),
      prescriptionLocal: PrescriptionLocalDatasource(),
      requestSync: _requestSync,
    );
    addTearDown(service.dispose);
  }

  final String name;
  final String path;
  final SupabaseClient client;
  final String userId;
  bool online = true;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  late final SyncService service;
  late final MedicationRepositoryImpl medications;
  late final TreatmentRepositoryImpl treatments;
  late final DoseLogRepositoryImpl doses;
  final List<Future<void>> _requests = [];

  /// Every cycle this device ran, in order.
  final List<SyncReport> reports = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll().then((r) {
      if (r != null) reports.add(r);
    });
    _requests.add(cycle);
    return cycle;
  }

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

  /// One cycle; it must end clean.
  Future<SyncReport> sync() => run((_) async {
    final report = (await service.syncAll())!;
    reports.add(report);
    expect(
      report.isClean,
      isTrue,
      reason: '$name: ${report.fatal} ${report.failures}',
    );
    return report;
  });

  /// This device's rows of [table] with [id] (none, or one).
  Future<List<Map<String, Object?>>> rows(String table, String id) =>
      run((db) => db.query(table, where: 'id = ?', whereArgs: [id]));
}

/// A folder for device databases, removed after the test.
Future<String> deviceFolder() async {
  final dir = await Directory.systemTemp.createTemp('medora_it_');
  addTearDown(() async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = null;
    await dir.delete(recursive: true);
  });
  return dir.path;
}
