/// Convergence test against a local Supabase (`supabase start`).
/// Run: fvm flutter test test/integration --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=ANON_KEY
/// (the anon key printed by `supabase status`).
/// Skipped automatically when the defines are absent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../helpers/test_database.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  final configured = _url.isNotEmpty && _key.isNotEmpty;

  late SupabaseClient client;
  late String userId;

  setUpAll(() async {
    if (!configured) return;
    // No plugin channels in tests: the PKCE flow needs an async storage that
    // only `Supabase.initialize` provides, and auto-refresh would leave a
    // timer running past the test.
    client = SupabaseClient(
      _url,
      _key,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    final email = 'it-${const Uuid().v4()}@example.com';
    final res =
        await client.auth.signUp(email: email, password: 'password-123');
    userId = res.user!.id;
    expect(client.auth.currentSession, isNotNull,
        reason: 'local Supabase must auto-confirm sign-ups');
  });

  tearDownAll(() async {
    if (!configured) return;
    await client.dispose();
  });

  /// A "device": fresh in-memory local DB + its own cursors, same account.
  Future<SyncService> device() async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = inMemoryDatabasePath;
    return SyncService(
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
      cursors: SyncCursorStore.inMemory(),
      isOnline: () => true,
      currentUserId: () => userId,
      onlineStream: const Stream.empty(),
    );
  }

  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('create on A, pull on B, delete on B, gone on A', () async {
    final id = const Uuid().v4();

    // Device A creates and pushes.
    final a = await device();
    await MedicationLocalDatasource().upsert(
      MedicationModel(id: id, name: 'Convergence', quantity: 1),
      syncStatus: SyncStatus.pendingCreate,
    );
    final r1 = (await a.syncAll())!;
    expect(r1.isClean, isTrue, reason: r1.failures.join('\n'));

    // Device B pulls, deletes, pushes the tombstone.
    final b = await device();
    final r2 = (await b.syncAll())!;
    expect(r2.isClean, isTrue, reason: r2.failures.join('\n'));
    expect(await MedicationLocalDatasource().getMedicationById(id), isNotNull);
    await MedicationLocalDatasource().markDeleted(id);
    final r3 = (await b.syncAll())!;
    expect(r3.isClean, isTrue, reason: r3.failures.join('\n'));

    // Device A (fresh state again) pulls: tombstone applied.
    final a2 = await device();
    final r4 = (await a2.syncAll())!;
    expect(r4.isClean, isTrue, reason: r4.failures.join('\n'));
    expect(await MedicationLocalDatasource().getMedicationById(id), isNull);
  },
      skip: configured
          ? false
          : 'Set SUPABASE_URL and SUPABASE_ANON_KEY dart-defines to run '
              'against a local Supabase');
}
