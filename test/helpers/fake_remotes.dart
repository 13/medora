import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

/// A fake Supabase table: JSON rows keyed by id, server-stamped `updated_at`,
/// soft delete via `deleted_at`.
class FakeRemoteTable {
  FakeRemoteTable(this.clock);

  final DateTime Function() clock;
  final Map<String, Map<String, dynamic>> rows = {};
  final Set<String> failIds = {};
  final List<DateTime?> sinceCalls = [];

  /// When set, every delta fetch (`since`) throws — a whole-table fetch
  /// failure rather than a per-row one.
  Object? throwOnFetch;

  /// Optional gate awaited before every [since] and [upsert]. A test can hold
  /// a cycle open on a `Completer` and call back into the service meanwhile.
  Future<void> Function()? beforeCall;

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  /// Insert keeps the client's `updated_at` (or stamps now); update stamps now
  /// like the `update_updated_at` trigger.
  Future<void> upsert(Map<String, dynamic> json) async {
    await beforeCall?.call();
    final id = json['id'] as String;
    _guard(id);
    final now = clock().toUtc().toIso8601String();
    final existing = rows[id];
    final merged = {...?existing, ...json};
    merged['updated_at'] = existing == null ? (json['updated_at'] ?? now) : now;
    rows[id] = merged;
  }

  void tombstone(String id) {
    _guard(id);
    final existing = rows[id];
    if (existing == null) return;
    final now = clock().toUtc().toIso8601String();
    rows[id] = {...existing, 'deleted_at': now, 'updated_at': now};
  }

  void hardDelete(String id) {
    _guard(id);
    rows.remove(id);
  }

  List<Map<String, dynamic>> all() =>
      rows.values.map(Map<String, dynamic>.from).toList();

  /// Live rows only — mirrors the `.isFilter('deleted_at', null)` the
  /// non-delta remote getters apply. Delta pulls use [since] and still see
  /// tombstones.
  List<Map<String, dynamic>> live() =>
      all().where((r) => r['deleted_at'] == null).toList();

  Future<List<Map<String, dynamic>>> since(DateTime? since) async {
    await beforeCall?.call();
    sinceCalls.add(since);
    final failure = throwOnFetch;
    if (failure != null) throw failure;
    if (since == null) return all();
    return all().where((r) {
      final u = r['updated_at'] as String?;
      return u != null && DateTime.parse(u).toUtc().isAfter(since.toUtc());
    }).toList();
  }

  /// The stored `updated_at` for [id], or null when the row is absent —
  /// mirrors `select('updated_at').eq('id', id).maybeSingle()`.
  DateTime? updatedAt(String id) {
    final raw = rows[id]?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// Test helper: seed a row that is already synced remotely.
  void seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    rows[json['id'] as String] = {
      ...json,
      'updated_at': (updatedAt ?? clock()).toUtc().toIso8601String(),
    };
  }
}

class FakeMedicationRemote implements MedicationRemoteDatasource {
  FakeMedicationRemote(DateTime Function() clock)
    : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<DateTime?> getUpdatedAt(String id) async => table.updatedAt(id);

  @override
  Future<List<MedicationModel>> getMedications() async =>
      table.live().map(MedicationModel.fromJson).toList();
  @override
  Future<List<MedicationModel>> getMedicationsSince(DateTime? since) async =>
      (await table.since(since)).map(MedicationModel.fromJson).toList();
  @override
  Future<MedicationModel> getMedicationById(String id) async =>
      MedicationModel.fromJson(table.rows[id]!);
  @override
  Future<List<MedicationModel>> searchMedications(String query) async =>
      (await getMedications()).where((m) => m.name.contains(query)).toList();
  @override
  Future<void> addMedication(MedicationModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> updateMedication(MedicationModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> upsertMedication(MedicationModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> deleteMedication(String id) async => table.tombstone(id);
  @override
  Future<void> updateQuantity(String id, int delta) async {
    final row = table.rows[id]!;
    await table.upsert({...row, 'quantity': (row['quantity'] as int) + delta});
  }
}

class FakeTreatmentRemote implements TreatmentRemoteDatasource {
  FakeTreatmentRemote(DateTime Function() clock)
    : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<DateTime?> getUpdatedAt(String id) async => table.updatedAt(id);

  @override
  Future<List<TreatmentModel>> getTreatments() async =>
      table.live().map(TreatmentModel.fromJson).toList();
  @override
  Future<List<TreatmentModel>> getTreatmentsSince(DateTime? since) async =>
      (await table.since(since)).map(TreatmentModel.fromJson).toList();
  @override
  Future<List<TreatmentModel>> getActiveTreatments() async =>
      (await getTreatments()).where((t) => t.isActive).toList();
  @override
  Future<TreatmentModel> getTreatmentById(String id) async =>
      TreatmentModel.fromJson(table.rows[id]!);
  @override
  Future<void> addTreatment(TreatmentModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> updateTreatment(TreatmentModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> upsertTreatment(TreatmentModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> deleteTreatment(String id) async => table.tombstone(id);
  @override
  Future<void> endTreatment(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': false});
}

class FakePrescriptionRemote implements PrescriptionRemoteDatasource {
  FakePrescriptionRemote(DateTime Function() clock)
    : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<DateTime?> getUpdatedAt(String id) async => table.updatedAt(id);

  @override
  Future<List<PrescriptionModel>> getPrescriptions() async =>
      table.live().map(PrescriptionModel.fromJson).toList();
  @override
  Future<List<PrescriptionModel>> getPrescriptionsSince(
    DateTime? since,
  ) async =>
      (await table.since(since)).map(PrescriptionModel.fromJson).toList();
  @override
  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(
    String treatmentId,
  ) async => (await getPrescriptions())
      .where((p) => p.treatmentId == treatmentId)
      .toList();
  @override
  Future<List<PrescriptionModel>> getActivePrescriptions() async =>
      (await getPrescriptions()).where((p) => p.isActive).toList();
  @override
  Future<PrescriptionModel> getPrescriptionById(String id) async =>
      PrescriptionModel.fromJson(table.rows[id]!);
  @override
  Future<void> addPrescription(PrescriptionModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> updatePrescription(PrescriptionModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> upsertPrescription(PrescriptionModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> deletePrescription(String id) async => table.tombstone(id);
  @override
  Future<void> deactivatePrescription(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': false});
  @override
  Future<void> reactivatePrescription(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': true});
}

class FakeDoseLogRemote implements DoseLogRemoteDatasource {
  FakeDoseLogRemote(DateTime Function() clock) : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<DateTime?> getUpdatedAt(String id) async => table.updatedAt(id);

  @override
  Future<List<DoseLogModel>> getDoseLogs() async =>
      table.live().map(DoseLogModel.fromJson).toList();
  @override
  Future<List<DoseLogModel>> getDoseLogsSince(DateTime? since) async =>
      (await table.since(since)).map(DoseLogModel.fromJson).toList();
  @override
  Future<List<DoseLogModel>> getTodaysDoseLogs() async => getDoseLogs();
  @override
  Future<void> addDoseLog(DoseLogModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> addDoseLogsBatch(List<DoseLogModel> models) async {
    for (final m in models) {
      await table.upsert(m.toJson());
    }
  }

  @override
  Future<void> upsertDoseLog(DoseLogModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> updateDoseLogStatus(
    String id,
    String status, {
    DateTime? takenTime,
  }) async => table.upsert({
    ...table.rows[id]!,
    'status': status,
    'taken_time': takenTime?.toUtc().toIso8601String(),
  });
  @override
  Future<void> deleteDoseLog(String id) async => table.tombstone(id);
}

class FakeFamilyRemote implements FamilyRemoteDatasource {
  FakeFamilyRemote(DateTime Function() clock, {this.currentUserId = 'user-a'})
    : families = FakeRemoteTable(clock),
      members = FakeRemoteTable(clock);
  final FakeRemoteTable families;
  final FakeRemoteTable members;
  String currentUserId;

  @override
  Future<FamilyModel> createFamily(FamilyModel family) async {
    await families.upsert(family.toJson());
    return FamilyModel.fromJson(families.rows[family.id]!);
  }

  @override
  Future<void> upsertFamily(FamilyModel family) async =>
      families.upsert(family.toJson());
  @override
  Future<FamilyModel?> getFamilyByInviteCode(String code) async {
    final matches = families.all().where((r) => r['invite_code'] == code);
    return matches.isEmpty ? null : FamilyModel.fromJson(matches.first);
  }

  @override
  Future<FamilyModel?> getFamilyById(String id) async {
    final row = families.rows[id];
    return row == null ? null : FamilyModel.fromJson(row);
  }

  @override
  Future<FamilyMemberModel> addMember(FamilyMemberModel member) async {
    await members.upsert(member.toJson());
    return FamilyMemberModel.fromJson(members.rows[member.id]!);
  }

  @override
  Future<void> upsertMember(FamilyMemberModel member) async =>
      members.upsert(member.toJson());
  @override
  Future<List<FamilyMemberModel>> getMembers(String familyId) async => members
      .all()
      .where((r) => r['family_id'] == familyId)
      .map(FamilyMemberModel.fromJson)
      .toList();
  @override
  Future<void> removeMember(String memberId) async =>
      members.hardDelete(memberId);
  @override
  Future<FamilyMemberModel?> getCurrentMembership() async {
    final matches = members.all().where((r) => r['user_id'] == currentUserId);
    return matches.isEmpty ? null : FamilyMemberModel.fromJson(matches.first);
  }

  @override
  Future<String> regenerateInviteCode(String familyId) async {
    await families.upsert({
      ...families.rows[familyId]!,
      'invite_code': 'NEWCODE',
    });
    return 'NEWCODE';
  }

  @override
  Future<void> deleteFamily(String familyId) async =>
      families.hardDelete(familyId);
  @override
  Future<({FamilyModel family, FamilyMemberModel member})> joinFamily(
    String inviteCode,
    String displayName,
  ) async {
    final family = await getFamilyByInviteCode(inviteCode);
    if (family == null) throw StateError('Invalid invite code');
    final member = FamilyMemberModel(
      id: 'member-$currentUserId',
      familyId: family.id,
      userId: currentUserId,
      displayName: displayName,
      role: 'member',
    );
    await members.upsert(member.toJson());
    return (
      family: family,
      member: FamilyMemberModel.fromJson(members.rows[member.id]!),
    );
  }
}
