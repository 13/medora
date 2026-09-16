import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/pull_page.dart';
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

  /// Ids whose single-row fetch ([get]) throws — a server that cannot be
  /// reached while the user is discarding a stuck row.
  final Set<String> failGetIds = {};
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
  /// like the `update_updated_at` trigger. Returns the stored `updated_at`,
  /// as `upsert(...).select('updated_at')` does.
  Future<DateTime?> upsert(Map<String, dynamic> json) async {
    await beforeCall?.call();
    final id = json['id'] as String;
    _guard(id);
    final now = clock().toUtc().toIso8601String();
    final existing = rows[id];
    final merged = {...?existing, ...json};
    merged['updated_at'] = existing == null ? (json['updated_at'] ?? now) : now;
    rows[id] = merged;
    return updatedAt(id);
  }

  /// Inserts the rows whose id is not there yet, keeping each client
  /// `updated_at` (no `BEFORE INSERT` trigger), and leaves the others alone
  /// — `upsert(rows, ignoreDuplicates: true)`. Returns how many it inserted.
  Future<int> insertIfAbsent(List<Map<String, dynamic>> jsons) async {
    await beforeCall?.call();
    for (final json in jsons) {
      _guard(json['id'] as String);
    }
    insertBatches.add(jsons.length);
    var inserted = 0;
    for (final json in jsons) {
      final id = json['id'] as String;
      if (rows.containsKey(id)) continue;
      rows[id] = {
        ...json,
        'updated_at': json['updated_at'] ?? clock().toUtc().toIso8601String(),
      };
      inserted++;
    }
    return inserted;
  }

  /// The size of every [insertIfAbsent] request, in order.
  final List<int> insertBatches = [];

  /// The rows with these ids, tombstones included — `select().inFilter`.
  Future<List<Map<String, dynamic>>> getMany(List<String> ids) async {
    await beforeCall?.call();
    return [
      for (final id in ids)
        if (rows[id] != null) Map<String, dynamic>.from(rows[id]!),
    ];
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
  /// non-delta remote getters apply. Delta pulls use [page] and still see
  /// tombstones.
  List<Map<String, dynamic>> live() =>
      all().where((r) => r['deleted_at'] == null).toList();

  /// The most rows one fetch answers, whatever it asked for — the PostgREST
  /// `max_rows` a hosted Supabase project applies (1000 by default). A
  /// longer answer is cut short without any sign.
  int rowCap = 1000;

  /// Every page request, in order: the `since` and `after` it asked with.
  final List<({DateTime? since, PullKey? after})> pageCalls = [];

  /// Optional hook run on every page request before it is answered; a test
  /// can throw from it to fail one page.
  void Function(int call, DateTime? since, PullKey? after)? onPage;

  /// One page of a delta pull, as `pullPage` asks the server for it: rows
  /// changed after [since] (all rows when null), tombstones included, that
  /// come after [after] in `updated_at, id` order, in that order, at most
  /// [limit] and at most [rowCap] of them.
  Future<List<Map<String, dynamic>>> page(
    DateTime? since,
    PullKey? after, {
    int limit = pullPageSize,
  }) async {
    await beforeCall?.call();
    sinceCalls.add(since);
    pageCalls.add((since: since, after: after));
    onPage?.call(pageCalls.length, since, after);
    final failure = throwOnFetch;
    if (failure != null) throw failure;
    final matching = [
      for (final r in all())
        if (_stampOf(r) case final u?)
          if (since == null || u.isAfter(since.toUtc()))
            if (after == null || _compareKey(u, r['id'] as String, after) > 0)
              r,
    ]..sort(_compareRows);
    return matching.take(limit < rowCap ? limit : rowCap).toList();
  }

  static DateTime? _stampOf(Map<String, dynamic> row) {
    final raw = row['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  static int _compareKey(DateTime stamp, String id, PullKey key) {
    final byStamp = stamp.compareTo(key.updatedAt.toUtc());
    return byStamp != 0 ? byStamp : id.compareTo(key.id);
  }

  static int _compareRows(Map<String, dynamic> a, Map<String, dynamic> b) =>
      _compareKey(
        _stampOf(a)!,
        a['id'] as String,
        PullKey(_stampOf(b)!, b['id'] as String),
      );

  /// One row by id, or null when it is absent — mirrors
  /// `.eq('id', id).maybeSingle()`.
  Map<String, dynamic>? get(String id) {
    if (failGetIds.contains(id)) throw StateError('remote get failure for $id');
    return rows[id];
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
  Future<List<MedicationModel>> getMedicationsSince(
    DateTime? since, {
    PullKey? after,
  }) async =>
      (await table.page(since, after)).map(MedicationModel.fromJson).toList();
  @override
  Future<MedicationModel?> getMedicationById(String id) async {
    final row = table.get(id);
    return row == null ? null : MedicationModel.fromJson(row);
  }

  @override
  Future<List<MedicationModel>> searchMedications(String query) async =>
      (await getMedications()).where((m) => m.name.contains(query)).toList();
  @override
  Future<DateTime?> upsertMedication(MedicationModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> deleteMedication(String id) async => table.tombstone(id);
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
  Future<List<TreatmentModel>> getTreatmentsSince(
    DateTime? since, {
    PullKey? after,
  }) async =>
      (await table.page(since, after)).map(TreatmentModel.fromJson).toList();
  @override
  Future<List<TreatmentModel>> getActiveTreatments() async =>
      (await getTreatments()).where((t) => t.isActive).toList();
  @override
  Future<TreatmentModel?> getTreatmentById(String id) async {
    final row = table.get(id);
    return row == null ? null : TreatmentModel.fromJson(row);
  }

  @override
  Future<DateTime?> upsertTreatment(TreatmentModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> deleteTreatment(String id) async => table.tombstone(id);
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
    DateTime? since, {
    PullKey? after,
  }) async =>
      (await table.page(since, after)).map(PrescriptionModel.fromJson).toList();
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
  Future<PrescriptionModel?> getPrescriptionById(String id) async {
    final row = table.get(id);
    return row == null ? null : PrescriptionModel.fromJson(row);
  }

  @override
  Future<DateTime?> upsertPrescription(PrescriptionModel model) async {
    final json = model.toJson();
    json['start_time'] = asTimestamptz(json['start_time'] as String);
    return table.upsert(json);
  }

  /// What a `timestamptz` column in a UTC session gives back for [raw]: a
  /// time without an offset is read as UTC, and the answer always carries
  /// one (`2026-03-01T08:00:00+00:00`), which `DateTime.parse` turns into a
  /// UTC value.
  static String asTimestamptz(String raw) {
    final hasOffset = RegExp(
      r'(Z|[+-]\d{2}(:?\d{2})?)$',
    ).hasMatch(raw.substring(raw.indexOf('T') + 1));
    final utc = hasOffset
        ? DateTime.parse(raw).toUtc()
        : DateTime.parse('${raw}Z');
    final text = utc.toIso8601String();
    return '${text.substring(0, text.length - 1)}+00:00';
  }

  @override
  Future<void> deletePrescription(String id) async => table.tombstone(id);
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
  Future<List<DoseLogModel>> getDoseLogsSince(
    DateTime? since, {
    PullKey? after,
  }) async =>
      (await table.page(since, after)).map(DoseLogModel.fromJson).toList();
  @override
  Future<DoseLogModel?> getDoseLogById(String id) async {
    final row = table.get(id);
    return row == null ? null : DoseLogModel.fromJson(row);
  }

  @override
  Future<List<DoseLogModel>> getTodaysDoseLogs() async => getDoseLogs();
  @override
  Future<DateTime?> upsertDoseLog(DoseLogModel model) async =>
      table.upsert(model.toJson());
  @override
  Future<void> insertDoseLogsIfAbsent(List<DoseLogModel> models) async =>
      table.insertIfAbsent([for (final m in models) m.toJson()]);
  @override
  Future<List<DoseLogModel>> getDoseLogsByIds(List<String> ids) async =>
      (await table.getMany(ids)).map(DoseLogModel.fromJson).toList();
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
