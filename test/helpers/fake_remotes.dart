/// The fake remote datasources: thin views of one [FakeServerCore]
/// (`fake_server.dart`), which models the server rules. With
/// [FakeTransport.http] their requests go through the app's PostgREST
/// datasources and [FakePostgrest].
library;

import 'dart:typed_data';

import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/rx_remote_datasource.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, StorageException;

import 'fake_postgrest.dart';
import 'fake_server.dart';

export 'fake_server.dart';

/// One fake Supabase project: the shared core and a datasource per table.
class FakeServer {
  /// [medicationRows], [treatmentRows] and [doseRows] build a misbehaving
  /// table in place of the plain one; such a table picks its own transport.
  FakeServer(
    DateTime Function() clock, {
    String currentUserId = 'user-a',
    FakeSyncTable Function(FakeServerCore core)? medicationRows,
    FakeSyncTable Function(FakeServerCore core)? treatmentRows,
    FakeSyncTable Function(FakeServerCore core)? doseRows,
    this.transport = defaultFakeTransport,
  }) : core = FakeServerCore(clock) {
    meds = FakeMedicationRemote(
      core,
      rows: medicationRows?.call(core),
      transport: transport,
    );
    treatments = FakeTreatmentRemote(
      core,
      rows: treatmentRows?.call(core),
      transport: transport,
    );
    prescriptions = FakePrescriptionRemote(core, transport: transport);
    doses = FakeDoseLogRemote(
      core,
      rows: doseRows?.call(core),
      transport: transport,
    );
    rx = FakeRxRemote(core, transport: transport);
    attachments = FakeAttachmentRemote(
      core,
      currentUserId: currentUserId,
      transport: transport,
    );
    families = FakeFamilyRemote(clock, currentUserId: currentUserId);
    state = FakeSyncState(core, transport: transport);
  }

  final FakeServerCore core;
  final FakeTransport transport;
  late final FakeMedicationRemote meds;
  late final FakeTreatmentRemote treatments;
  late final FakePrescriptionRemote prescriptions;
  late final FakeDoseLogRemote doses;

  /// Persons, prescription documents and their dispensings.
  late final FakeRxRemote rx;

  /// Attachment rows and the bucket holding their bytes.
  late final FakeAttachmentRemote attachments;
  late final FakeFamilyRemote families;
  late final FakeSyncState state;
}

class FakeMedicationRemote implements MedicationRemoteDatasource {
  /// [rows] replaces the plain table, for a test that needs a server that
  /// misbehaves.
  FakeMedicationRemote(
    FakeServerCore core, {
    FakeSyncTable? rows,
    FakeTransport? transport,
  }) : rows = rows ?? FakeSyncTable(core, 'medications', transport: transport),
       stock = FakeStockRemote(core, transport: transport);

  @override
  final FakeSyncTable rows;
  @override
  final FakeStockRemote stock;

  /// [rows], under the name older tests use.
  FakeSyncTable get table => rows;
}

class FakeTreatmentRemote implements TreatmentRemoteDatasource {
  FakeTreatmentRemote(
    FakeServerCore core, {
    FakeSyncTable? rows,
    FakeTransport? transport,
  }) : rows = rows ?? FakeSyncTable(core, 'treatments', transport: transport);

  @override
  final FakeSyncTable rows;
  FakeSyncTable get table => rows;
}

class FakePrescriptionRemote implements PrescriptionRemoteDatasource {
  FakePrescriptionRemote(FakeServerCore core, {FakeTransport? transport})
    : rows = FakePrescriptionTable(core, transport: transport);

  @override
  final FakePrescriptionTable rows;
  FakeSyncTable get table => rows;

  /// What a `timestamptz` column in a UTC session gives back for [raw]: a
  /// time without an offset is read as UTC, and the answer always carries
  /// one (`2026-03-01T08:00:00+00:00`).
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
}

/// Stores `start_time` the way a `timestamptz` column does.
class FakePrescriptionTable extends FakeSyncTable {
  FakePrescriptionTable(FakeServerCore core, {super.transport})
    : super(core, 'prescriptions');

  static Map<String, Object?> _asStored(Map<String, Object?> json) => {
    ...json,
    if (json['start_time'] case final String t)
      'start_time': FakePrescriptionRemote.asTimestamptz(t),
  };

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => super.patch(
    id,
    _asStored(changes),
    ifVersion: ifVersion,
    ifStatus: ifStatus,
    ifLive: ifLive,
  );

  @override
  Future<List<Map<String, dynamic>>> patchMany(
    List<String> ids,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => super.patchMany(
    ids,
    _asStored(changes),
    ifVersion: ifVersion,
    ifStatus: ifStatus,
    ifLive: ifLive,
  );

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) =>
      super.insertIfAbsent([for (final r in rows) _asStored(r)]);
}

class FakeDoseLogRemote implements DoseLogRemoteDatasource {
  FakeDoseLogRemote(
    FakeServerCore core, {
    FakeSyncTable? rows,
    FakeTransport? transport,
  }) : rows = rows ?? FakeSyncTable(core, 'dose_logs', transport: transport);

  @override
  final FakeSyncTable rows;
  FakeSyncTable get table => rows;
}

class FakeRxRemote implements RxRemoteDatasource {
  FakeRxRemote(FakeServerCore core, {FakeTransport? transport})
    : persons = FakeSyncTable(core, 'persons', transport: transport),
      rx = FakeSyncTable(core, 'rx', transport: transport),
      dispensings = FakeSyncTable(core, 'rx_dispensings', transport: transport);

  @override
  final FakeSyncTable persons;
  @override
  final FakeSyncTable rx;
  @override
  final FakeSyncTable dispensings;

  /// A project that never ran [rxMigration]: none of the three tables is
  /// there.
  void dropTables() {
    for (final t in [persons, rx, dispensings]) {
      t.missingFrom = rxMigration;
    }
  }
}

class FakeAttachmentRemote implements AttachmentRemoteDatasource {
  FakeAttachmentRemote(
    FakeServerCore core, {
    String currentUserId = 'user-a',
    FakeTransport? transport,
  }) : rows = FakeSyncTable(core, 'attachments', transport: transport),
       store = FakeAttachmentStore(currentUserId: currentUserId);

  @override
  final FakeSyncTable rows;
  @override
  final FakeAttachmentStore store;

  /// A project that never ran [attachmentsMigration]: no table (and no
  /// bucket).
  void dropTable() => rows.missingFrom = attachmentsMigration;
}

/// The private `attachments` bucket in memory. Like the storage policies,
/// it refuses any path outside the current user's folder
/// (`<currentUserId>/...`), with the error storage-api gives.
class FakeAttachmentStore implements AttachmentStore {
  FakeAttachmentStore({this.currentUserId = 'user-a'});

  /// Whose folder the caller may use.
  String currentUserId;

  /// The stored objects by path.
  final Map<String, Uint8List> objects = {};

  /// The MIME type each object was uploaded with.
  final Map<String, String> mimes = {};

  int uploads = 0;
  int downloads = 0;
  int removes = 0;
  int lists = 0;

  /// The next this many calls (of any kind) throw, as a network error.
  int failNext = 0;

  /// The folder [path] sits in, as `storage.foldername(name)[1]`; null for
  /// a path outside any folder.
  static String? ownerOf(String path) {
    final slash = path.indexOf('/');
    return slash <= 0 ? null : path.substring(0, slash);
  }

  void _call() {
    if (failNext > 0) {
      failNext--;
      throw const StorageException(
        'Connection refused',
        statusCode: 'ClientException',
      );
    }
  }

  bool _mine(String path) => ownerOf(path) == currentUserId;

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required String mime,
  }) async {
    uploads++;
    _call();
    if (!_mine(path)) {
      throw const StorageException(
        'new row violates row-level security policy',
        error: 'Unauthorized',
        statusCode: '403',
      );
    }
    // Already there counts as done, as SupabaseAttachmentStore does.
    if (objects.containsKey(path)) return;
    objects[path] = Uint8List.fromList(bytes);
    mimes[path] = mime;
  }

  @override
  Future<Uint8List> download(String path) async {
    downloads++;
    _call();
    final bytes = _mine(path) ? objects[path] : null;
    if (bytes == null) throw AttachmentNotFound(path);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> remove(List<String> paths) async {
    removes++;
    _call();
    for (final path in paths) {
      // Another user's objects are silently left alone.
      if (_mine(path)) {
        objects.remove(path);
        mimes.remove(path);
      }
    }
  }

  @override
  Future<List<String>> listFolder(String folder) async {
    lists++;
    _call();
    if (folder != currentUserId) return const [];
    return [
      for (final path in objects.keys)
        if (path.startsWith('$folder/') &&
            !path.substring(folder.length + 1).contains('/'))
          path,
    ]..sort();
  }
}

class FakeSyncState implements SyncStateRemoteDatasource {
  FakeSyncState(this.core, {FakeTransport? transport})
    : _http = (transport ?? defaultFakeTransport) == FakeTransport.http
          ? FakePostgrest.of(core)
          : null;

  final FakeServerCore core;
  final FakePostgrest? _http;

  /// False: the project lacks the sync v2 migration.
  bool migrated = true;

  @override
  Future<SyncServerState> read() async {
    final http = _http;
    if (http != null) {
      http.migrated = migrated;
      return http.state.read();
    }
    if (!migrated) {
      throw const MissingMigrationException(
        migration: syncV2Migration,
        cause: PostgrestException(
          message:
              'Could not find the function public.medora_sync_state without '
              'parameters in the schema cache',
          code: 'PGRST202',
        ),
      );
    }
    return parseSyncState(core.syncState());
  }
}

/// The families' tables, which sync v2 leaves as they were: JSON rows by id.
class FakeRemoteTable {
  FakeRemoteTable(this.clock);

  final DateTime Function() clock;
  final Map<String, Map<String, dynamic>> rows = {};

  /// Ids whose writes throw, as a server that refuses them.
  final Set<String> failIds = {};

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  Future<void> upsert(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    _guard(id);
    rows[id] = {...?rows[id], ...json};
  }

  void hardDelete(String id) {
    _guard(id);
    rows.remove(id);
  }

  /// A row already on the server.
  void seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    rows[json['id'] as String] = {
      ...json,
      'updated_at': (updatedAt ?? clock()).toUtc().toIso8601String(),
    };
  }

  List<Map<String, dynamic>> all() =>
      rows.values.map(Map<String, dynamic>.from).toList();
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
