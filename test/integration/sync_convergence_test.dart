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
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
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

  /// A "device": fresh in-memory local DB + its own cursors. Defaults to the
  /// account created in `setUpAll`; pass [as]/[asUserId] for a second account.
  Future<SyncService> device({SupabaseClient? as, String? asUserId}) async {
    final c = as ?? client;
    final uid = asUserId ?? userId;
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = inMemoryDatabasePath;
    return SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: MedicationRemoteDatasource(c),
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: TreatmentRemoteDatasource(c),
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: PrescriptionRemoteDatasource(c),
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: DoseLogRemoteDatasource(c),
      familyLocal: FamilyLocalDatasource(),
      familyRemote: FamilyRemoteDatasource(c),
      cursors: SyncCursorStore.inMemory(),
      isOnline: () => true,
      currentUserId: () => uid,
      onlineStream: const Stream.empty(),
    );
  }

  /// A second, independent account with its own client (a second person, not
  /// a second device of the same person).
  Future<({SupabaseClient client, String userId})> secondAccount() async {
    final other = SupabaseClient(
      _url,
      _key,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    addTearDown(other.dispose);
    final res = await other.auth.signUp(
      email: 'it-${const Uuid().v4()}@example.com',
      password: 'password-123',
    );
    return (client: other, userId: res.user!.id);
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

  test('B joins A\'s family by invite code and both sync it down', () async {
    final familyId = const Uuid().v4();
    final inviteCode = const Uuid().v4().substring(0, 8).toUpperCase();

    // A creates the family and their own membership row.
    final aRemote = FamilyRemoteDatasource(client);
    await aRemote.createFamily(FamilyModel(
      id: familyId,
      name: 'Convergence Family',
      inviteCode: inviteCode,
      ownerId: userId,
    ));
    await aRemote.upsertMember(FamilyMemberModel(
      id: const Uuid().v4(),
      familyId: familyId,
      userId: userId,
      displayName: 'A',
      role: 'owner',
    ));

    // B is a different person: second sign-up, second client.
    final b = await secondAccount();
    final joined = await FamilyRemoteDatasource(b.client)
        .joinFamily(inviteCode, 'B');
    expect(joined.family.id, familyId);
    expect(joined.member.userId, b.userId);

    // A's device syncs: the owner sees the whole roster.
    final aDevice = await device();
    final ra = (await aDevice.syncAll())!;
    expect(ra.isClean, isTrue, reason: ra.failures.join('\n'));
    final aMembers = await FamilyLocalDatasource().getMembers(familyId);
    expect(aMembers.map((m) => m.userId), containsAll([userId, b.userId]),
        reason: 'the family owner can read every member row');
    expect(await FamilyLocalDatasource().getFamilyById(familyId), isNotNull);

    // B's device syncs: B reaches the family (via is_family_member) and their
    // own membership row.
    //
    // B does NOT see A's row. `family_members_select` is
    // `user_id = auth.uid() OR is_family_owner(family_id)`, so a non-owner
    // member only ever reads themselves. That is the policy as it stands on
    // both migrations; widening it to the whole roster is a deliberate
    // product/security decision, not something this test should assume.
    final bDevice = await device(as: b.client, asUserId: b.userId);
    final rb = (await bDevice.syncAll())!;
    expect(rb.isClean, isTrue, reason: rb.failures.join('\n'));
    expect(await FamilyLocalDatasource().getFamilyById(familyId), isNotNull,
        reason: 'a plain member can read the family itself');
    final bMembers = await FamilyLocalDatasource().getMembers(familyId);
    expect(bMembers.map((m) => m.userId), [b.userId]);
  },
      skip: configured
          ? false
          : 'Set SUPABASE_URL and SUPABASE_ANON_KEY dart-defines to run '
              'against a local Supabase');
}
