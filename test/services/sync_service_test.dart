import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class Harness {
  Harness({
    DateTime? start,
    StreamController<bool>? online,
    FamilyLocalDatasource? familyLocal,
    FakeSyncTable Function(FakeServerCore core)? medicationRows,
    FakeSyncTable Function(FakeServerCore core)? doseRows,
    FakeServer? server,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration capRetryDelay = const Duration(seconds: 15),
    int maxPullPages = SyncService.defaultMaxPullPages,
    SyncCursorStore? cursors,
  }) : clock = TestClock(start ?? DateTime.utc(2026, 3, 4, 12)) {
    this.server =
        server ??
        FakeServer(
          clock.now,
          medicationRows: medicationRows,
          doseRows: doseRows,
        );
    core = this.server.core;
    meds = this.server.meds;
    treatments = this.server.treatments;
    prescriptions = this.server.prescriptions;
    doses = this.server.doses;
    family = this.server.families;
    this.cursors = cursors ?? SyncCursorStore.inMemory();
    failures = SyncFailureStore.inMemory();
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: doses,
      familyLocal: familyLocal ?? FamilyLocalDatasource(),
      familyRemote: family,
      syncState: this.server.state,
      cursors: this.cursors,
      failures: failures,
      isOnline: () => this.online,
      currentUserId: () => userId,
      onlineStream: online?.stream ?? const Stream<bool>.empty(),
      now: clock.now,
      requestTimeout: requestTimeout,
      capRetryDelay: capRetryDelay,
      maxPullPages: maxPullPages,
    );
    // A retry armed at the re-run cap must not fire into a later test.
    addTearDown(service.dispose);
  }

  final TestClock clock;
  late final FakeServer server;
  late final FakeServerCore core;
  bool online = true;
  String? userId = 'user-a';
  late final FakeMedicationRemote meds;
  late final FakeTreatmentRemote treatments;
  late final FakePrescriptionRemote prescriptions;
  late final FakeDoseLogRemote doses;
  late final FakeFamilyRemote family;
  late final SyncCursorStore cursors;
  late final SyncFailureStore failures;
  late final SyncService service;
}

/// A local family store whose final "drop the family row" step fails, so the
/// dedicated pending_delete batch records a push failure for the row.
class FailingFamilyDelete extends FamilyLocalDatasource {
  @override
  Future<void> deleteFamily(String id) async =>
      throw StateError('cannot drop family $id');
}

/// A medication table whose every write is joined by a local edit of the
/// same row, as a writer that touches the row on every cycle would do: the
/// cycle always finds the row changed after its push. Stops after [limit]
/// edits so a missing cap fails the test instead of hanging it.
class EditOnEveryPushTable extends FakeSyncTable {
  EditOnEveryPushTable(FakeServerCore core, {this.limit = 50})
    : super(core, 'medications');

  final int limit;
  int upserts = 0;

  Future<void> _editLocally(String id) async {
    upserts++;
    if (upserts > limit) return;
    final db = await AppDatabase.instance.database;
    final row = (await localRow('medications', id))!;
    final stamp = DateTime.parse(row['updated_at']! as String);
    await db.update(
      'medications',
      {
        'name': 'edit $upserts',
        'updated_at': stamp
            .add(const Duration(milliseconds: 1))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    await _editLocally(id);
    return super.patch(
      id,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    for (final r in rows) {
      await _editLocally(r['id']! as String);
    }
    return super.insertIfAbsent(rows);
  }
}

/// A dose table whose batch insert lands and whose answer then never comes
/// while [hang] is set — a response lost to a timeout.
class HangingInsertTable extends FakeSyncTable {
  HangingInsertTable(FakeServerCore core) : super(core, 'dose_logs');

  Completer<void>? hang;

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    await super.insertIfAbsent(rows);
    final gate = hang;
    if (gate != null) await gate.future;
  }
}

/// A dose table that refuses a whole insert statement, as PostgREST does,
/// when one of its rows breaks a rule: an id in [rejectIds] (a constraint),
/// or a prescription the server does not have (the foreign key and the
/// row-level policy). Its read-back can leave out [hideIds].
class RejectingDoseTable extends FakeSyncTable {
  RejectingDoseTable(FakeServerCore core) : super(core, 'dose_logs');

  final Set<String> rejectIds = {};
  final Set<String> hideIds = {};

  /// When set, a dose whose prescription this table lacks is refused.
  FakeSyncTable? prescriptions;

  /// When set, the read-back never answers.
  Object? readBackError;

  /// Every insert request, as the ids it carried.
  final List<List<String>> inserts = [];

  /// The ids sent with a row update, in order.
  final List<String> upserted = [];

  /// When set, a row update gets no answer.
  Object? upsertError;

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) {
    upserted.add(id);
    final error = upsertError;
    if (error != null) throw error;
    return super.patch(
      id,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    inserts.add([for (final r in rows) r['id']! as String]);
    for (final r in rows) {
      if (rejectIds.contains(r['id'])) {
        throw const PostgrestException(
          message: 'check violation',
          code: '23514',
        );
      }
      final known = prescriptions;
      if (known != null && !known.rows.containsKey(r['prescription_id'])) {
        throw const PostgrestException(
          message: 'insert or update violates foreign key constraint',
          code: '23503',
        );
      }
    }
    return super.insertIfAbsent(rows);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    final error = readBackError;
    if (error != null) throw error;
    return [
      for (final d in await super.fetchMany(ids))
        if (!hideIds.contains(d['id'])) d,
    ];
  }
}

/// Seeds a prescription and generates its whole schedule as `pending_create`
/// rows, as the app does; returns the prescription id and the dose ids.
Future<(String, List<String>)> seedSchedule({required int durationDays}) async {
  final db = await AppDatabase.instance.database;
  final seeded = await seedPrescription(db, durationDays: durationDays);
  final generated = await DoseLogRepositoryImpl(
    localDatasource: DoseLogLocalDatasource(),
    prescriptionLocal: PrescriptionLocalDatasource(),
  ).generateDoseLogsForPrescription(seeded.prescriptionId);
  return (seeded.prescriptionId, [for (final d in generated.dataOrNull!) d.id]);
}

Future<List<String>> syncStatuses(List<String> ids) async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query('dose_logs', columns: ['id', 'sync_status']);
  final byId = {for (final r in rows) r['id']: r['sync_status'] as String};
  return [for (final id in ids) byId[id] ?? 'gone'];
}

/// Hand-advanced clock shared by the service and the fake remotes.
class TestClock {
  TestClock(this._now);
  DateTime _now;
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

Future<Map<String, dynamic>?> localRow(String table, String id) async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
  return rows.isEmpty ? null : rows.first;
}

int cycles() => 1 + SyncService.maxAutomaticReruns;

/// A dose table that ignores where a page should start and answers the
/// first page every time, so a pull that trusted it would never end.
class EndlessPagesTable extends FakeSyncTable {
  EndlessPagesTable(FakeServerCore core) : super(core, 'dose_logs');

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) => super.page(after: null, horizon: horizon);
}

/// Seeds [count] dose rows of one local prescription on the server, the
/// i-th stamped [stampOf] (i). Their ids are random, so the id order is not
/// the seeding order. Returns the ids.
Future<List<String>> seedRemoteDoses(
  Harness h,
  int count,
  DateTime Function(int i) stampOf,
) async {
  final db = await AppDatabase.instance.database;
  final presc = await seedPrescription(db);
  final ids = <String>[];
  for (var i = 0; i < count; i++) {
    final id = const Uuid().v4();
    ids.add(id);
    h.doses.table.seed(
      DoseLogModel(
        id: id,
        prescriptionId: presc.prescriptionId,
        scheduledTime: DateTime.utc(2026, 3).add(Duration(minutes: i)),
      ).toJson(),
      updatedAt: stampOf(i),
    );
  }
  return ids;
}

Future<int> localDoseCount() async {
  final db = await AppDatabase.instance.database;
  final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM dose_logs');
  return rows.single['n']! as int;
}

/// The server's older copy of the medication `m-busy`.
void seedBusyRemote(Harness h) => h.meds.table.seed(
  const MedicationModel(id: 'm-busy', name: 'Server', quantity: 1).toJson(),
  updatedAt: h.clock.now().subtract(const Duration(days: 1)),
);

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  SyncService makeLocalOnly() => SyncService(
    medicationLocal: MedicationLocalDatasource(),
    medicationRemote: null,
    syncState: null,
    treatmentLocal: TreatmentLocalDatasource(),
    treatmentRemote: null,
    prescriptionLocal: PrescriptionLocalDatasource(),
    prescriptionRemote: null,
    doseLogLocal: DoseLogLocalDatasource(),
    doseLogRemote: null,
    familyLocal: FamilyLocalDatasource(),
    familyRemote: null,
  );

  test('local-only service is unavailable and syncAll is a no-op', () async {
    final service = makeLocalOnly();
    expect(service.isAvailable, isFalse);
    await service.syncAll();
    expect(service.currentState, SyncState.idle);
    service.dispose();
  });

  test('dispose is idempotent and later state changes do not throw', () {
    final service = makeLocalOnly();
    service.dispose();
    expect(service.dispose, returnsNormally);
    expect(
      () => service.debugSetStateForTest(SyncState.success),
      returnsNormally,
    );
  });

  group('with fake remotes', () {
    test('pushes a pending local medication and marks it synced', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'm1', name: 'Moment', quantity: 3),
        syncStatus: SyncStatus.pendingCreate,
      );
      await h.service.syncAll();
      expect(h.meds.table.rows['m1']?['name'], 'Moment');
      expect(
        (await localRow('medications', 'm1'))?['sync_status'],
        SyncStatus.synced,
      );
      expect(h.service.currentState, SyncState.success);
    });

    test('clearing the pack EAN clears it on the server too', () async {
      // Review I1: an omitted `ean` key means "leave it alone" to PostgREST,
      // so the cleared EAN would survive on the server and be pulled back —
      // and then match a pack that is no longer this medication.
      final h = Harness();
      final local = MedicationLocalDatasource();
      await local.upsert(
        MedicationModel(
          id: 'm-ean',
          name: 'Zinco-C',
          quantity: 1,
          barcode: '107018',
          ean: '8057737141836',
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingCreate,
      );
      await h.service.syncAll();
      expect(h.meds.table.rows['m-ean']?['ean'], '8057737141836');

      h.clock.advance(const Duration(minutes: 5));
      await local.upsert(
        MedicationModel(
          id: 'm-ean',
          name: 'Zinco-C',
          quantity: 1,
          barcode: '107019',
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      await h.service.syncAll();

      expect(h.meds.table.rows['m-ean']?['barcode'], '107019');
      expect(h.meds.table.rows['m-ean']?['ean'], isNull);
      // And a device pulling that row ends with no EAN either.
      expect(MedicationModel.fromJson(h.meds.table.rows['m-ean']!).ean, isNull);
    });

    test(
      'a pending treatment pushes its sick-leave columns to the server',
      () async {
        final h = Harness();
        await TreatmentLocalDatasource().upsert(
          TreatmentModel(
            id: 't1',
            name: 'Stirnhöhlenentzündung',
            startDate: DateTime(2026, 3, 2),
            sickLeaveFrom: DateTime(2026, 3, 3),
            sickLeaveTo: DateTime(2026, 3, 9),
            sickLeaveRef: '1234567890',
            doctor: 'Dr. Rossi, Bozen',
          ),
          syncStatus: SyncStatus.pendingCreate,
        );

        await h.service.syncAll();

        final remote = h.treatments.table.rows['t1']!;
        expect(remote['sick_leave_from'], '2026-03-03');
        expect(remote['sick_leave_to'], '2026-03-09');
        expect(remote['sick_leave_ref'], '1234567890');
        expect(remote['doctor'], 'Dr. Rossi, Bozen');
        expect(
          (await localRow('treatments', 't1'))?['sync_status'],
          SyncStatus.synced,
        );
      },
    );

    test('a pulled treatment stores its sick-leave columns locally', () async {
      final h = Harness();
      h.treatments.table.seed({
        'id': 't2',
        'name': 'Grippe',
        'start_date': '2026-02-01',
        'is_active': true,
        'sick_leave_from': '2026-02-02',
        'sick_leave_to': '2026-02-05',
        'sick_leave_ref': 'AB-42',
        'doctor': 'Dr. Bianchi',
      });

      await h.service.syncAll();

      final stored = (await TreatmentLocalDatasource().getTreatmentById('t2'))!;
      expect(stored.sickLeaveFrom, DateTime(2026, 2, 2));
      expect(stored.sickLeaveTo, DateTime(2026, 2, 5));
      expect(stored.sickLeaveRef, 'AB-42');
      expect(stored.doctor, 'Dr. Bianchi');
    });

    test('pulls a remote medication into the local database', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(
          id: 'm2',
          name: 'Tachipirina',
          quantity: 1,
        ).toJson(),
      );
      await h.service.syncAll();
      expect((await localRow('medications', 'm2'))?['name'], 'Tachipirina');
      expect(
        (await localRow('medications', 'm2'))?['sync_status'],
        SyncStatus.synced,
      );
    });

    test('remote newer than local pending wins; local newer is kept', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      // Local pending edit at T+10min, remote edit at T+20min → remote wins.
      await local.upsert(
        MedicationModel(
          id: 'm3',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().add(const Duration(minutes: 10)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm3', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(minutes: 20)),
      );
      // Push happens first and would overwrite remote; make the push fail so
      // the pull phase decides.
      h.meds.table.failIds.add('m3');
      await h.service.syncAll();
      expect((await localRow('medications', 'm3'))?['name'], 'Remote');
    });

    test(
      'remote tombstone hard-deletes the local row even if locally pending',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'm4', name: 'Gone', quantity: 1).toJson(),
        );
        h.meds.table.tombstone('m4');
        await MedicationLocalDatasource().upsert(
          const MedicationModel(id: 'm4', name: 'Gone', quantity: 1),
          syncStatus: SyncStatus.pendingUpdate,
        );
        // Push fails, so the row is still pending when the pull phase runs.
        h.meds.table.failIds.add('m4');
        await h.service.syncAll();
        expect(await localRow('medications', 'm4'), isNull);
      },
    );

    test('local delete pushes a tombstone and hard-deletes locally', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'm5', name: 'Bye', quantity: 1).toJson(),
      );
      await h.service.syncAll(); // now local synced
      await MedicationLocalDatasource().markDeleted('m5');
      expect((await localRow('medications', 'm5'))?['deleted_at'], isNotNull);
      await h.service.syncAll();
      expect(h.meds.table.rows['m5']?['deleted_at'], isNotNull);
      expect(await localRow('medications', 'm5'), isNull);
    });

    test(
      'a live-row push does not clear an existing remote tombstone',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'm6', name: 'Zombie', quantity: 1).toJson(),
        );
        h.meds.table.tombstone('m6');
        await MedicationLocalDatasource().upsert(
          const MedicationModel(id: 'm6', name: 'Zombie', quantity: 1),
          syncStatus: SyncStatus.pendingUpdate,
        );
        await h.service.syncAll();
        expect(await localRow('medications', 'm6'), isNull);
        expect(h.meds.table.rows['m6']?['deleted_at'], isNotNull);
      },
    );

    test(
      'a remotely deleted treatment cascades to local prescriptions and dose logs',
      () async {
        final h = Harness();
        final db = await AppDatabase.instance.database;
        final seeded = await seedPrescription(db);
        await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
        h.treatments.table.seed(
          (await TreatmentLocalDatasource().getTreatmentById(
            seeded.treatmentId,
          ))!.toJson(),
        );
        h.treatments.table.tombstone(seeded.treatmentId);
        await h.service.syncAll();
        expect(await localRow('treatments', seeded.treatmentId), isNull);
        expect(await localRow('prescriptions', seeded.prescriptionId), isNull);
        expect(await db.query('dose_logs'), isEmpty);
      },
    );

    test('local newer is kept', () async {
      final h = Harness();
      // Remote edit at T+5min, local pending edit at T+20min → local wins.
      h.meds.table.seed(
        const MedicationModel(id: 'm7', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(minutes: 5)),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm7',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().add(const Duration(minutes: 20)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // Push would overwrite remote; make it fail so the pull phase decides.
      h.meds.table.failIds.add('m7');
      await h.service.syncAll();
      expect((await localRow('medications', 'm7'))?['name'], 'Local');
    });

    test(
      'local pending_delete is not overwritten by a newer live remote row',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'm8', name: 'Old', quantity: 1).toJson(),
        );
        await h.service.syncAll(); // local copy is synced
        await MedicationLocalDatasource().markDeleted('m8');
        // Another device edits the row after our delete; the tombstone push fails.
        h.clock.advance(const Duration(minutes: 5));
        h.meds.table.seed(
          const MedicationModel(id: 'm8', name: 'Newer', quantity: 2).toJson(),
        );
        h.meds.table.failIds.add('m8');
        await h.service.syncAll();
        final row = await localRow('medications', 'm8');
        expect(row?['sync_status'], SyncStatus.pendingDelete);
        expect(row?['name'], 'Old');
      },
    );

    test('a pending update with no base meets a newer server copy and takes '
        'it', () async {
      final h = Harness();
      // Local edit at T+10min, remote edit at T+20min, and nothing known
      // about the server copy (a row from before sync v2): the push reads
      // the server copy and merges by edit time.
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm9',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().add(const Duration(minutes: 10)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm9', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(minutes: 20)),
      );

      final report = (await h.service.syncAll())!;

      expect(report.merged, 1);
      final overwrite = report.overwritten.single;
      expect(overwrite.id, 'm9');
      expect(overwrite.columns, {'name'});
      expect(overwrite.keptLocal, isFalse);
      expect(report.failures, isEmpty);
      expect(h.service.currentState, SyncState.success);
      expect(h.meds.table.rows['m9']?['name'], 'Remote');
      final row = await localRow('medications', 'm9');
      expect(row?['name'], 'Remote');
      expect(row?['sync_status'], SyncStatus.synced);
    });

    test('a server copy the pull already went past is merged by the push, '
        'not skipped', () async {
      final h = Harness();
      final t = h.clock.now();
      h.meds.table.seed(
        const MedicationModel(id: 'm9b', name: 'Remote', quantity: 1).toJson(),
        updatedAt: t.add(const Duration(minutes: 20)),
      );
      // This device's pull key is already past that row.
      await h.cursors.setPullKey('medications', PullKey(h.core.horizon));
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm9b',
          name: 'Local',
          quantity: 1,
          updatedAt: t.add(const Duration(minutes: 10)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      expect(report.merged, 1);
      final row = await localRow('medications', 'm9b');
      expect(row?['name'], 'Remote');
      expect(row?['sync_status'], SyncStatus.synced);
    });

    test('a pending update edited after the server copy is pushed', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm10',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 5)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm10', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(minutes: 20)),
      );

      final report = (await h.service.syncAll())!;

      expect(report.pushed, 1);
      expect(report.overwritten.single.keptLocal, isTrue);
      expect(h.meds.table.rows['m10']?['name'], 'Local');
      final row = (await localRow('medications', 'm10'))!;
      expect(row['name'], 'Local');
      expect(row['sync_status'], SyncStatus.synced);
      expect(row['sync_version'], h.meds.table.rows['m10']!['row_version']);
    });

    test('a pending create meets a newer server copy and takes it; a '
        'tombstone still wins over a newer live row', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      // pending_create whose id already exists remotely, edited later.
      await local.upsert(
        MedicationModel(
          id: 'm11',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(hours: 1)),
        ),
        syncStatus: SyncStatus.pendingCreate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm11', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
      );
      // pending_delete against a newer remote row.
      h.meds.table.seed(
        const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
      );
      await local.upsert(
        const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1),
        syncStatus: SyncStatus.synced,
      );
      await local.markDeleted('m12');

      await h.service.syncAll();

      expect(h.meds.table.rows['m11']?['name'], 'Remote');
      expect((await localRow('medications', 'm11'))?['name'], 'Remote');
      expect(h.meds.table.rows['m12']?['deleted_at'], isNotNull);
      expect(await localRow('medications', 'm12'), isNull);
    });

    test('force push ignores a newer remote row', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm13',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm13', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(hours: 1)),
      );

      final report = (await h.service.forcePush())!;

      expect(report.pushed, 1);
      expect(h.meds.table.rows['m13']?['name'], 'Local');
    });

    test('skips when offline or signed out', () async {
      final h = Harness()..online = false;
      await h.service.syncAll();
      expect(h.service.currentState, SyncState.idle);
      h.online = true;
      h.userId = null;
      await h.service.syncAll();
      expect(h.service.currentState, SyncState.idle);
    });
  });

  group('report', () {
    test('counts pushes and pulls and ends clean', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'a', name: 'A', quantity: 1),
        syncStatus: SyncStatus.pendingCreate,
      );
      h.treatments.table.seed(
        TreatmentModel(
          id: 't',
          name: 'T',
          startDate: DateTime(2026, 3),
        ).toJson(),
      );
      final report = await h.service.syncAll();
      expect(report, isNotNull);
      expect(report!.pushed, 1);
      // Only 't': 'a' was written after this cycle's horizon, so the next
      // cycle sees it (and keeps it, being the same version).
      expect(report.pulled, 1);
      expect(report.failures, isEmpty);
      expect(report.finishedAt, isNotNull);
      expect(h.service.lastReport, same(report));
      expect(h.service.currentState, SyncState.success);
    });

    test('a project without the sync migration stops the cycle before any '
        'table request', () async {
      final h = Harness();
      h.server.state.migrated = false;
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'a', name: 'A', quantity: 1),
        syncStatus: SyncStatus.pendingCreate,
      );

      final report = (await h.service.syncAll())!;

      expect(
        report.missingMigration,
        'supabase/migrations/20260918000000_sync_v2.sql',
      );
      expect(
        report.fatal,
        contains('Apply supabase/migrations/20260918000000_sync_v2.sql'),
      );
      expect(h.core.requests, isEmpty);
      expect(h.service.currentState, SyncState.error);
      expect(
        (await localRow('medications', 'a'))!['sync_status'],
        SyncStatus.pendingCreate,
      );
    });

    test('a failing row is recorded and the state is partial', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      await local.upsert(
        const MedicationModel(id: 'ok', name: 'ok', quantity: 1),
        syncStatus: SyncStatus.pendingCreate,
      );
      await local.upsert(
        const MedicationModel(id: 'bad', name: 'bad', quantity: 1),
        syncStatus: SyncStatus.pendingCreate,
      );
      h.meds.table.failIds.add('bad');
      final report = (await h.service.syncAll())!;
      expect(report.pushed, 1);
      expect(report.failures.map((f) => f.id), ['bad']);
      expect(report.failures.single.table, 'medications');
      expect(h.service.currentState, SyncState.partial);
      expect(
        (await localRow('medications', 'bad'))?['sync_status'],
        SyncStatus.pendingCreate,
      );
    });

    test('tombstones are counted as deleted', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'z', name: 'z', quantity: 1).toJson(),
      );
      await h.service.syncAll();
      h.meds.table.tombstone('z');
      final report = (await h.service.syncAll())!;
      expect(report.deleted, 1);
    });
  });

  group('failing-row backoff', () {
    Future<void> seedFailingMedication(Harness h) async {
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'bad', name: 'bad', quantity: 1),
        syncStatus: SyncStatus.pendingCreate,
      );
      h.meds.table.failIds.add('bad');
    }

    test(
      'a failed row is recorded and skipped until its backoff is up',
      () async {
        final h = Harness();
        await seedFailingMedication(h);

        final first = (await h.service.syncAll())!;
        expect(first.failures.map((f) => f.id), ['bad']);
        expect(first.skippedBackoff, 0);
        expect((await h.failures.get('medications', 'bad'))?.count, 1);

        // One minute later the 2-minute backoff has not elapsed: skipped, and
        // the failure is not re-reported.
        h.clock.advance(const Duration(minutes: 1));
        h.service.debugSetStateForTest(SyncState.idle);
        final second = (await h.service.syncAll())!;
        expect(second.skippedBackoff, 1);
        expect(second.failures.where((f) => f.table == 'medications'), isEmpty);
        expect((await h.failures.get('medications', 'bad'))?.count, 1);

        // Past the backoff it is retried — and fails again, doubling the count.
        h.clock.advance(const Duration(minutes: 2));
        h.service.debugSetStateForTest(SyncState.idle);
        final third = (await h.service.syncAll())!;
        expect(third.skippedBackoff, 0);
        expect(third.failures.map((f) => f.id), ['bad']);
        expect((await h.failures.get('medications', 'bad'))?.count, 2);
      },
    );

    test('a row that pushes again clears its failure record', () async {
      final h = Harness();
      await seedFailingMedication(h);
      await h.service.syncAll();
      expect(await h.failures.get('medications', 'bad'), isNotNull);

      h.meds.table.failIds.remove('bad');
      h.clock.advance(const Duration(minutes: 5));
      h.service.debugSetStateForTest(SyncState.idle);
      final report = (await h.service.syncAll())!;

      expect(report.pushed, 1);
      expect(report.failures, isEmpty);
      expect(await h.failures.get('medications', 'bad'), isNull);
      expect(h.meds.table.rows['bad'], isNotNull);
    });

    test(
      'discardFailedRow takes the server copy and clears the record',
      () async {
        final h = Harness();
        await seedFailingMedication(h);
        h.meds.table.seed(
          const MedicationModel(
            id: 'bad',
            name: 'Server',
            quantity: 7,
          ).toJson(),
          updatedAt: h.clock.now().add(const Duration(hours: 2)),
        );
        await h.service.syncAll();
        expect(await h.failures.get('medications', 'bad'), isNotNull);

        await h.service.discardFailedRow('medications', 'bad');

        final row = await localRow('medications', 'bad');
        expect(
          row?['name'],
          'Server',
          reason: 'discarding must replace the local row, not just stamp it',
        );
        expect(row?['quantity'], 7);
        expect(row?['sync_status'], SyncStatus.synced);
        expect(await h.failures.get('medications', 'bad'), isNull);

        // The next cycle no longer tries to push it at all.
        h.clock.advance(const Duration(hours: 1));
        h.service.debugSetStateForTest(SyncState.idle);
        final report = (await h.service.syncAll())!;
        expect(report.pushed, 0);
        expect(report.failures, isEmpty);
        expect(report.skippedBackoff, 0);
      },
    );

    test('force pull forgets every failure record', () async {
      final h = Harness();
      await seedFailingMedication(h);
      await h.service.syncAll();
      expect(await h.failures.get('medications', 'bad'), isNotNull);

      h.service.debugSetStateForTest(SyncState.idle);
      await h.service.forcePull();

      expect(
        await h.failures.listAll(),
        isEmpty,
        reason: 'the rows those records described no longer exist',
      );
    });

    test('discardFailedRow deletes a row the server does not have', () async {
      final h = Harness();
      await seedFailingMedication(h);
      await h.service.syncAll();

      await h.service.discardFailedRow('medications', 'bad');

      expect(await localRow('medications', 'bad'), isNull);
      expect(await h.failures.get('medications', 'bad'), isNull);
    });

    test('discarding a pending_delete keeps the server copy', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      h.meds.table.seed(
        const MedicationModel(
          id: 'doomed',
          name: 'Server',
          quantity: 1,
        ).toJson(),
      );
      await local.upsert(
        const MedicationModel(id: 'doomed', name: 'Server', quantity: 1),
        syncStatus: SyncStatus.synced,
      );
      await local.markDeleted('doomed');
      h.meds.table.failIds.add('doomed');
      await h.service.syncAll();
      expect(await h.failures.get('medications', 'doomed'), isNotNull);

      await h.service.discardFailedRow('medications', 'doomed');

      final row = await localRow('medications', 'doomed');
      expect(row?['name'], 'Server');
      expect(row?['sync_status'], SyncStatus.synced);
      expect(row?['deleted_at'], isNull);
      expect(h.meds.table.rows['doomed']?['deleted_at'], isNull);
    });

    test('discardFailedRow rethrows and leaves the row pending when the fetch '
        'fails', () async {
      final h = Harness();
      await seedFailingMedication(h);
      await h.service.syncAll();
      h.meds.table.failGetIds.add('bad');

      await expectLater(
        h.service.discardFailedRow('medications', 'bad'),
        throwsA(isA<StateError>()),
      );

      expect(
        (await localRow('medications', 'bad'))?['sync_status'],
        SyncStatus.pendingCreate,
      );
      expect(await h.failures.get('medications', 'bad'), isNotNull);
    });
  });

  group('edit times on the wire and from the server', () {
    test("a pulled row takes the server's edit times, not the ones held "
        'here (M-7)', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'm1', name: 'A', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(days: 2)),
      );
      await h.service.syncAll();
      final first = (await localRow('medications', 'm1'))!;
      expect(first['edited_at'], h.meds.table.rows['m1']!['edited_at']);
      expect(first['field_edited_at'], isNull); // the server's map is empty

      // What this device holds is older than what comes next.
      final db = await AppDatabase.instance.database;
      await db.update(
        'medications',
        {
          'edited_at': '2020-01-01T00:00:00.000Z',
          'field_edited_at':
              '{"name":{"at":"2020-01-01T00:00:00.000Z","auto":false}}',
        },
        where: 'id = ?',
        whereArgs: ['m1'],
      );
      h.clock.advance(const Duration(minutes: 5));
      h.meds.table.editFromOtherDevice('m1', {
        'name': 'B',
      }, editedAt: h.clock.now().subtract(const Duration(minutes: 1)));
      h.service.debugSetStateForTest(SyncState.idle);

      await h.service.syncAll();

      final server = h.meds.table.rows['m1']!;
      final local = (await localRow('medications', 'm1'))!;
      expect(local['name'], 'B');
      expect(local['sync_status'], SyncStatus.synced);
      expect(local['edited_at'], server['edited_at']);
      expect(
        jsonDecode(local['field_edited_at']! as String),
        server['field_edited_at'],
      );
      expect(
        (server['field_edited_at'] as Map)['name'],
        isNot(containsPair('at', '2020-01-01T00:00:00.000Z')),
      );
    });

    test('a change here that the server already holds settles with the '
        "server's edit times", () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'm1', name: 'A', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(days: 2)),
      );
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      // The same edit, made here earlier and on the other device later.
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm1',
          name: 'B',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(hours: 2)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.editFromOtherDevice('m1', {
        'name': 'B',
      }, editedAt: h.clock.now().subtract(const Duration(hours: 1)));

      final report = (await h.service.syncAll())!;

      expect(report.overwritten, isEmpty);
      final server = h.meds.table.rows['m1']!;
      final local = (await localRow('medications', 'm1'))!;
      expect(local['sync_status'], SyncStatus.synced);
      expect(local['sync_version'], server['row_version']);
      expect(local['edited_at'], server['edited_at']);
      expect(
        jsonDecode(local['field_edited_at']! as String),
        server['field_edited_at'],
      );
    });

    test('a force push is a change made the moment it runs, column by '
        'column', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'm1', name: 'Server', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(days: 2)),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm1',
          name: 'Mine',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(days: 3)),
        ),
        syncStatus: SyncStatus.synced,
      );

      await h.service.forcePush();

      final now = h.clock.now().toUtc().toIso8601String();
      final sent = h.meds.table.sent.single;
      expect(sent['edited_at'], now);
      expect((sent['field_edited_at']! as Map)['name'], {
        'at': now,
        'auto': false,
      });
      final server = h.meds.table.rows['m1']!;
      expect(server['name'], 'Mine');
      expect(server['edited_at'], now);
      expect((server['field_edited_at'] as Map)['name'], {
        'at': now,
        'auto': false,
      });
    });

    test('every write the cycle sends carries its edit time and column '
        'times', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      for (final id in ['m-edit', 'm-gone']) {
        h.meds.table.seed(
          MedicationModel(id: id, name: id, quantity: 1).toJson(),
          updatedAt: h.clock.now().subtract(const Duration(days: 1)),
        );
      }
      await local.upsert(
        MedicationModel(
          id: 'm-new',
          name: 'New',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingCreate,
      );
      final (prescriptionId, ids) = await seedSchedule(durationDays: 1);
      // One generated dose is already overdue when the first push runs.
      final doses = DoseLogLocalDatasource();
      await doses.markOverduePendingAsMissed(DateTime(2026, 3, 1, 9));
      await h.service.syncAll();

      await local.upsert(
        MedicationModel(
          id: 'm-edit',
          name: 'Edited',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      await local.markDeleted('m-gone');
      // The schedule changed: its pending doses go as guarded deletes.
      expect(await doses.dropPendingByPrescription(prescriptionId), 2);
      h.clock.advance(const Duration(minutes: 5));
      h.service.debugSetStateForTest(SyncState.idle);
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      await h.service.forcePush();

      final sent = [...h.meds.table.sent, ...h.doses.table.sent];
      // Creates, the batch, an edit, both kinds of delete, force pushes.
      expect(h.meds.table.sent.length, greaterThanOrEqualTo(5));
      expect(h.doses.table.sent.length, greaterThanOrEqualTo(ids.length + 2));
      for (final write in sent) {
        expect(
          write,
          containsPair('field_edited_at', isA<Map<String, Object?>>()),
        );
        expect(write['edited_at'], isA<String>(), reason: '$write');
        expect(write['write_id'], isA<String>(), reason: '$write');
      }
    });

    test('a new dose goes out with its column times, in a batch with doses '
        'that have none', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 1);
      // Overdue before it was ever sent: the app marked it missed.
      expect(
        (await DoseLogLocalDatasource().markOverduePendingAsMissed(
          DateTime(2026, 3, 1, 9),
        )).changed,
        1,
      );

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      expect(h.doses.table.insertBatches, [ids.length]);
      const auto = {'at': '1970-01-01T00:00:00.000Z', 'auto': true};
      final swept = h.doses.table.rows[ids.first]!;
      expect(swept['status'], 'missed');
      expect((swept['field_edited_at'] as Map)['status'], auto);
      expect(swept['edited_at'], '1970-01-01T00:00:00.000Z');
      for (final id in ids.skip(1)) {
        expect(h.doses.table.rows[id]!['field_edited_at'], isEmpty);
      }
      expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
    });
  });

  group('delta pull', () {
    test(
      'first pull is full; the next starts at the first one\'s horizon',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
        );
        final horizon = h.core.horizon;
        final xidA = h.meds.table.rows['a']!['sync_xid'] as int;
        await h.service.syncAll();
        // One page with the row, and the empty page that ends the table.
        expect(h.meds.table.sinceCalls, [null, PullKey(xidA, 'a')]);
        expect(await h.cursors.pullKey('medications'), PullKey(horizon));

        h.clock.advance(const Duration(minutes: 5));
        h.meds.table.seed(
          const MedicationModel(id: 'b', name: 'B', quantity: 1).toJson(),
        );
        h.service.debugSetStateForTest(SyncState.idle);
        final calls = h.meds.table.sinceCalls.length;
        final report = (await h.service.syncAll())!;
        expect(h.meds.table.sinceCalls[calls], PullKey(horizon));
        // Only the new row: nothing overlaps.
        expect(report.pulled, 1);
        expect((await localRow('medications', 'b'))?['name'], 'B');
      },
    );

    test('generated doses are pulled once, not on every cycle', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 1);
      // Another device's generated copies: on the server, not here.
      for (final id in ids) {
        final row = (await localRow('dose_logs', id))!;
        h.doses.table.seed(
          DoseLogModel.fromLocalMap(row).toJson(),
          updatedAt: DateTime.utc(1970),
        );
      }
      final db = await AppDatabase.instance.database;
      await db.delete('dose_logs');

      final first = (await h.service.syncAll())!;
      expect(first.pulled, ids.length);

      h.clock.advance(const Duration(minutes: 5));
      final second = (await h.service.syncAll())!;
      expect(second.pulled, 0);
      expect(h.doses.table.sinceCalls.last, PullKey(h.core.horizon));
    });

    test('force pull clears cursors and pulls everything again', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
      );
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      final calls = h.meds.table.sinceCalls.length;
      await h.service.forcePull();
      expect(h.meds.table.sinceCalls[calls], isNull);
      expect((await localRow('medications', 'a'))?['name'], 'A');
    });

    test(
      'force pull is fatal, not partial, when a whole table cannot be fetched',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
        );
        await h.service.syncAll();
        expect(await localRow('medications', 'a'), isNotNull);
        h.service.debugSetStateForTest(SyncState.idle);

        // Force pull clears the local database first, so a failed fetch leaves
        // a hole: the cycle must report `error`, never `partial`.
        h.meds.table.throwOnFetch = StateError('network down');
        final report = (await h.service.forcePull())!;

        expect(report.fatal, 'force pull: medications fetch failed');
        expect(h.service.currentState, SyncState.error);
        expect(
          report.failures.any((f) => f.table == 'medications' && f.id == '*'),
          isTrue,
        );
      },
    );

    test(
      'an ordinary sync survives a whole-table fetch failure as partial',
      () async {
        final h = Harness();
        h.meds.table.throwOnFetch = StateError('network down');
        final report = (await h.service.syncAll())!;
        expect(report.fatal, isNull);
        expect(h.service.currentState, SyncState.partial);
      },
    );

    test('a pull error keeps the cursor unchanged', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
      );
      await h.service.syncAll();
      final before = await h.cursors.pullKey('medications');
      h.service.debugSetStateForTest(SyncState.idle);
      // Make apply fail for a new row: a row with no name breaks fromJson.
      h.meds.table.seed({'id': 'broken'});
      final report = (await h.service.syncAll())!;
      expect(
        report.failures.where((f) => f.table == 'medications'),
        isNotEmpty,
      );
      expect(await h.cursors.pullKey('medications'), before);
    });

    test('cursor does not advance when a row fails to apply', () async {
      final h = Harness();
      final db = await AppDatabase.instance.database;
      // A valid remote prescription (so `newest` is non-null on this table).
      final seeded = await seedPrescription(db);
      h.prescriptions.table.seed(
        (await PrescriptionLocalDatasource().getPrescriptionById(
          seeded.prescriptionId,
        ))!.toJson(),
      );
      // A remote prescription whose foreign keys point nowhere: `fromJson`
      // parses it fine, but the local insert violates
      // `PRAGMA foreign_keys = ON` and throws inside `upsert`.
      h.prescriptions.table.seed(
        PrescriptionModel(
          id: 'orphan',
          treatmentId: 'no-such-treatment',
          medicationId: 'no-such-med',
          dosage: '1',
          startTime: DateTime(2026, 3, 1, 8),
        ).toJson(),
      );
      final report = (await h.service.syncAll())!;
      final failure = report.failures.singleWhere(
        (f) => f.table == 'prescriptions' && f.id == 'orphan',
      );
      expect(failure.error, startsWith('apply:'));
      expect(report.pulled, 1); // only the valid prescription applied
      expect(await h.cursors.pullKey('prescriptions'), isNull);
    });
  });

  group('dose log last-write-wins', () {
    test(
      'remote wins when local pending update is older than the remote row',
      () async {
        final h = Harness();
        final db = await AppDatabase.instance.database;
        final seeded = await seedPrescription(db);
        final doseId = await seedDoseLog(
          db,
          seeded.prescriptionId,
          DateTime(2026, 3, 1, 8),
        );
        await db.update(
          'dose_logs',
          {
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': h.clock.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [doseId],
        );
        h.doses.table.seed(
          DoseLogModel(
            id: doseId,
            prescriptionId: seeded.prescriptionId,
            scheduledTime: DateTime(2026, 3, 1, 8),
            status: DoseStatus.taken,
          ).toJson(),
          updatedAt: h.clock.now().add(const Duration(minutes: 5)),
        );
        // Push would otherwise overwrite the remote row with the local one;
        // make it fail so the pull-side merge decides.
        h.doses.table.failIds.add(doseId);
        await h.service.syncAll();
        expect((await localRow('dose_logs', doseId))?['status'], 'taken');
      },
    );

    test(
      'local wins when the local pending update is newer than the remote row',
      () async {
        final h = Harness();
        final db = await AppDatabase.instance.database;
        final seeded = await seedPrescription(db);
        final doseId = await seedDoseLog(
          db,
          seeded.prescriptionId,
          DateTime(2026, 3, 1, 8),
        );
        h.doses.table.seed(
          DoseLogModel(
            id: doseId,
            prescriptionId: seeded.prescriptionId,
            scheduledTime: DateTime(2026, 3, 1, 8),
            status: DoseStatus.taken,
          ).toJson(),
          updatedAt: h.clock.now(),
        );
        await db.update(
          'dose_logs',
          {
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': h.clock
                .now()
                .add(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [doseId],
        );
        // Push would otherwise overwrite the remote row with the local one;
        // make it fail so the pull-side merge decides.
        h.doses.table.failIds.add(doseId);
        await h.service.syncAll();
        expect((await localRow('dose_logs', doseId))?['status'], 'pending');
      },
    );
  });

  group('family sync', () {
    test(
      'pushes pending members and removes pending_delete members remotely',
      () async {
        final h = Harness();
        final local = FamilyLocalDatasource();
        await local.upsertFamily(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ),
          syncStatus: SyncStatus.pendingCreate,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ),
          syncStatus: SyncStatus.pendingCreate,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'gone',
            familyId: 'f1',
            userId: 'user-b',
            role: 'member',
          ),
          syncStatus: SyncStatus.synced,
        );
        h.family.members.seed(
          const FamilyMemberModel(
            id: 'gone',
            familyId: 'f1',
            userId: 'user-b',
            role: 'member',
          ).toJson(),
        );
        await local.markMemberDeleted('gone');
        await h.service.syncAll();
        expect(h.family.families.rows['f1'], isNotNull);
        expect(h.family.members.rows['me'], isNotNull);
        expect(h.family.members.rows['gone'], isNull);
        expect(await localRow('family_members', 'gone'), isNull);
      },
    );

    test(
      'pull removes local synced members that no longer exist remotely',
      () async {
        final h = Harness();
        h.family.families.seed(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ).toJson(),
        );
        h.family.members.seed(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ).toJson(),
        );
        await FamilyLocalDatasource().upsertFamily(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ),
          syncStatus: SyncStatus.synced,
        );
        await FamilyLocalDatasource().upsertMember(
          const FamilyMemberModel(
            id: 'stale',
            familyId: 'f1',
            userId: 'user-z',
            role: 'member',
          ),
          syncStatus: SyncStatus.synced,
        );
        await h.service.syncAll();
        expect(await localRow('family_members', 'stale'), isNull);
        expect(await localRow('family_members', 'me'), isNotNull);
      },
    );

    test(
      're-pulling a family does not cascade-delete its local member rows',
      () async {
        // `family_members.family_id` cascades on delete, so an INSERT OR
        // REPLACE of the parent row would wipe every member row on every pull.
        final h = Harness();
        final local = FamilyLocalDatasource();
        await local.upsertFamily(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ),
          syncStatus: SyncStatus.synced,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ),
          syncStatus: SyncStatus.synced,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'mine',
            familyId: 'f1',
            userId: 'user-c',
            role: 'member',
          ),
          syncStatus: SyncStatus.pendingCreate,
        );
        h.family.families.seed(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ).toJson(),
        );
        h.family.members.seed(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ).toJson(),
        );
        h.family.members.failIds.add('mine');

        await h.service.syncAll();

        expect(
          await localRow('family_members', 'mine'),
          isNotNull,
          reason: 'a member row that failed to push must survive the pull',
        );
        expect(
          (await localRow('family_members', 'mine'))?['sync_status'],
          SyncStatus.pendingCreate,
        );
        expect(await localRow('family_members', 'me'), isNotNull);
      },
    );

    test(
      'a pull does not stamp a pending_delete member back to synced',
      () async {
        final h = Harness();
        final local = FamilyLocalDatasource();
        await local.upsertFamily(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ),
          syncStatus: SyncStatus.synced,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ),
          syncStatus: SyncStatus.synced,
        );
        h.family.families.seed(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'user-a',
          ).toJson(),
        );
        h.family.members.seed(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'owner',
          ).toJson(),
        );

        // The user leaves; the push of that removal fails, so the row is still
        // pending_delete when the pull runs and the member is still remote.
        await local.markMemberDeleted('me');
        h.family.members.failIds.add('me');
        await h.service.syncAll();

        expect(
          (await localRow('family_members', 'me'))?['sync_status'],
          SyncStatus.pendingDelete,
          reason:
              'the pull must not overwrite the local removal before it is pushed',
        );
        expect(h.family.members.rows['me'], isNotNull);
      },
    );

    test('a failing family leave keeps escalating its backoff', () async {
      // Families are visited by two push batches per cycle. The first one
      // must leave tombstones entirely alone: when it visited them it also
      // cleared the failure record the second batch had just written, and
      // the backoff count was reset to 1 on every cycle.
      final local = FailingFamilyDelete();
      final h = Harness(familyLocal: local);
      await local.upsertFamily(
        const FamilyModel(
          id: 'f1',
          name: 'S',
          inviteCode: 'X',
          ownerId: 'owner',
        ),
        syncStatus: SyncStatus.synced,
      );
      await local.upsertMember(
        const FamilyMemberModel(
          id: 'me',
          familyId: 'f1',
          userId: 'user-a',
          role: 'member',
        ),
        syncStatus: SyncStatus.synced,
      );
      h.family.members.seed(
        const FamilyMemberModel(
          id: 'me',
          familyId: 'f1',
          userId: 'user-a',
          role: 'member',
        ).toJson(),
      );
      await local.markMemberDeleted('me');
      await local.markFamilyDeleted('f1');

      final first = (await h.service.syncAll())!;
      expect(first.failures.map((f) => '${f.table}/${f.id}'), ['families/f1']);
      expect((await h.failures.get('families', 'f1'))?.count, 1);

      // Past the 2-minute backoff the row is retried and fails again.
      h.clock.advance(const Duration(minutes: 3));
      h.service.debugSetStateForTest(SyncState.idle);
      final second = (await h.service.syncAll())!;

      expect(second.failures.map((f) => '${f.table}/${f.id}'), ['families/f1']);
      expect(
        (await h.failures.get('families', 'f1'))?.count,
        2,
        reason:
            'the backoff must grow, not restart, while the push keeps '
            'failing',
      );
    });

    test(
      'a pending_delete family is dropped locally after its members are pushed',
      () async {
        final h = Harness();
        final local = FamilyLocalDatasource();
        await local.upsertFamily(
          const FamilyModel(
            id: 'f1',
            name: 'S',
            inviteCode: 'X',
            ownerId: 'owner',
          ),
          syncStatus: SyncStatus.synced,
        );
        await local.upsertMember(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'member',
          ),
          syncStatus: SyncStatus.synced,
        );
        h.family.members.seed(
          const FamilyMemberModel(
            id: 'me',
            familyId: 'f1',
            userId: 'user-a',
            role: 'member',
          ).toJson(),
        );
        await local.markMemberDeleted('me');
        await local.markFamilyDeleted('f1');
        await h.service.syncAll();
        expect(h.family.members.rows['me'], isNull);
        expect(await localRow('families', 'f1'), isNull);
        expect(await localRow('family_members', 'me'), isNull);
      },
    );
  });

  group('a row edited while the cycle pushes it', () {
    /// One pushed table: how to reach its fake, how to seed a pending local
    /// row plus an older server copy, and which column the edits change.
    Future<void> runCase(
      Harness h, {
      required String table,
      required FakeSyncTable remote,
      required String column,
      required Future<String> Function(Database db) seed,
      required Map<String, dynamic> Function(Map<String, dynamic> row) toServer,
    }) async {
      final db = await AppDatabase.instance.database;
      final id = await seed(db);
      remote.seed({
        ...toServer((await localRow(table, id))!),
        column: 'server copy',
      }, updatedAt: h.clock.now().subtract(const Duration(hours: 1)));
      // This device pulls the server copy: the row has its base.
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      remote.pageCalls.clear();
      final pushedAt = h.clock.now().subtract(const Duration(minutes: 2));
      await db.update(
        table,
        {
          column: 'pushed copy',
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': pushedAt.toIso8601String(),
          'edited_at': pushedAt.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      // Hold the push; edit the row meanwhile. The edit is stamped before the
      // server stamps the held push, as it is on a device in step with the
      // server.
      final release = Completer<void>();
      var held = false;
      String? statusAtPull;
      remote.beforeCall = () async {
        if (!held) {
          held = true;
          await db.update(
            table,
            {
              column: 'edited meanwhile',
              'updated_at': h.clock
                  .now()
                  .subtract(const Duration(minutes: 1))
                  .toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          await release.future;
          return;
        }
        // The first cycle's pull, right after the held push landed.
        statusAtPull ??= (await localRow(table, id))?['sync_status'] as String?;
      };

      final cycle = h.service.syncAll();
      await pumpEventQueue();
      release.complete();
      await cycle;

      expect(statusAtPull, SyncStatus.pendingUpdate, reason: table);
      // The cycle ran once more on its own and pushed the edit.
      expect(remote.sinceCalls.length, 2, reason: table);
      expect(remote.rows[id]?[column], 'edited meanwhile', reason: table);
      final stored = (await localRow(table, id))!;
      expect(stored[column], 'edited meanwhile', reason: table);
      expect(stored['sync_status'], SyncStatus.synced, reason: table);
    }

    test('medications: stays pending, is not pulled over, goes out on the '
        're-run', () async {
      final h = Harness();
      await runCase(
        h,
        table: 'medications',
        toServer: (row) => MedicationModel.fromLocalMap(row).toJson(),
        remote: h.meds.table,
        column: 'name',
        seed: (db) async => (await seedPrescription(db)).medicationId,
      );
    });

    test('treatments: stays pending, is not pulled over, goes out on the '
        're-run', () async {
      final h = Harness();
      await runCase(
        h,
        table: 'treatments',
        toServer: (row) => TreatmentModel.fromLocalMap(row).toJson(),
        remote: h.treatments.table,
        column: 'notes',
        seed: (db) async => (await seedPrescription(db)).treatmentId,
      );
    });

    test('prescriptions: stays pending, is not pulled over, goes out on the '
        're-run', () async {
      final h = Harness();
      await runCase(
        h,
        table: 'prescriptions',
        toServer: (row) => PrescriptionModel.fromLocalMap(row).toJson(),
        remote: h.prescriptions.table,
        column: 'notes',
        seed: (db) async => (await seedPrescription(db)).prescriptionId,
      );
    });

    test('dose logs: stay pending, are not pulled over, go out on the '
        're-run', () async {
      final h = Harness();
      await runCase(
        h,
        table: 'dose_logs',
        toServer: (row) => DoseLogModel.fromLocalMap(row).toJson(),
        remote: h.doses.table,
        column: 'notes',
        seed: (db) async => seedDoseLog(
          db,
          (await seedPrescription(db)).prescriptionId,
          DateTime(2026, 3, 1, 8),
        ),
      );
    });

    test('a row deleted while its push waits for the server is deleted, '
        'not marked synced', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'm-del', name: 'A', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(hours: 1)),
      );
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      // An earlier attempt got no answer, and the edit it carried was
      // undone since: nothing is left to send but the unknown outcome.
      final db = await AppDatabase.instance.database;
      await db.update(
        'medications',
        {'sync_status': SyncStatus.pendingUpdate, 'sync_write_id': 'lost-1'},
        where: 'id = ?',
        whereArgs: ['m-del'],
      );
      var held = false;
      h.meds.table.beforeCall = () async {
        if (held) return;
        held = true;
        // The person deletes the medication while the push asks the server
        // what became of that attempt.
        await MedicationLocalDatasource().markDeleted('m-del');
      };

      final report = (await h.service.syncAll())!;
      await h.service.syncAll();

      expect(report.failures, isEmpty);
      expect(h.meds.table.rows['m-del']!['deleted_at'], isNotNull);
      expect(await localRow('medications', 'm-del'), isNull);
    });

    test('a row with nothing to send that is edited while an earlier row '
        'is pushed is not marked synced', () async {
      final h = Harness();
      for (final id in ['m-first', 'm-second']) {
        h.meds.table.seed(
          MedicationModel(id: id, name: id, quantity: 1).toJson(),
          updatedAt: h.clock.now().subtract(const Duration(hours: 1)),
        );
      }
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      final db = await AppDatabase.instance.database;
      final local = MedicationLocalDatasource();
      await local.upsert(
        MedicationModel(
          id: 'm-first',
          name: 'first edited',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 3)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // Edited and edited back: pending, with nothing to send.
      await db.update(
        'medications',
        {'sync_status': SyncStatus.pendingUpdate},
        where: 'id = ?',
        whereArgs: ['m-second'],
      );
      var held = false;
      h.meds.table.beforeCall = () async {
        if (held) return;
        held = true;
        // While the first row goes out, the second is edited for real.
        await local.upsert(
          MedicationModel(
            id: 'm-second',
            name: 'second edited',
            quantity: 1,
            updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
          ),
          syncStatus: SyncStatus.pendingUpdate,
        );
      };

      await h.service.syncAll();

      expect(h.meds.table.rows['m-first']!['name'], 'first edited');
      expect(h.meds.table.rows['m-second']!['name'], 'second edited');
      final second = (await localRow('medications', 'm-second'))!;
      expect(second['name'], 'second edited');
      expect(second['sync_status'], SyncStatus.synced);
    });

    test('an unchanged pushed row takes the server stamp', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-stamp',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 3)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm-stamp', name: 'Old', quantity: 1).toJson(),
        updatedAt: h.clock.now().subtract(const Duration(hours: 1)),
      );
      // Pushes and pulls in one cycle; hide the pull so only the push's
      // bookkeeping can have set the stamp.
      h.meds.table.throwOnFetch = StateError('pull unavailable');

      await h.service.syncAll();

      final row = (await localRow('medications', 'm-stamp'))!;
      expect(row['sync_status'], SyncStatus.synced);
      expect(
        DateTime.parse(row['updated_at'] as String).toUtc(),
        h.meds.table.updatedAt('m-stamp'),
      );
    });
  });

  group('new dose logs', () {
    test('a generated schedule goes out in batches, not row by row', () async {
      final h = Harness();
      // 84 days, every 8 hours.
      final (_, ids) = await seedSchedule(durationDays: 84);
      expect(ids, hasLength(252));
      var calls = 0;
      h.doses.table.beforeCall = () async => calls++;

      final report = (await h.service.syncAll())!;

      expect(h.doses.table.insertBatches, [100, 100, 52]);
      // Three inserts, three reads back, one pull.
      expect(calls, 7);
      expect(report.pushed, 252);
      expect(report.failures, isEmpty);
      expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
      expect(h.doses.table.rows, hasLength(252));
    });

    test('a dose the server already has is left alone and adopted', () async {
      final h = Harness();
      final (prescriptionId, ids) = await seedSchedule(durationDays: 1);
      final taken = (await localRow('dose_logs', ids.first))!;
      h.doses.table.seed({
        ...DoseLogModel.fromLocalMap(taken).toJson(),
        'status': 'taken',
        'taken_time': h.clock.now().toIso8601String(),
      }, updatedAt: h.clock.now().subtract(const Duration(days: 30)));

      final report = (await h.service.syncAll())!;

      expect(report.pushed, ids.length);
      expect(h.doses.table.rows[ids.first]!['status'], 'taken');
      final local = (await localRow('dose_logs', ids.first))!;
      expect(local['status'], 'taken');
      expect(local['taken_time'], isNotNull);
      expect(local['sync_status'], SyncStatus.synced);
      expect(local['prescription_id'], prescriptionId);
      // The rest were inserted with the weakest stamp there is.
      expect(
        DateTime.parse(h.doses.table.rows[ids.last]!['updated_at'] as String),
        DateTime.utc(1970),
      );
    });

    test('a server tombstone deletes the local copy', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 1);
      final deletedAt = h.clock.now().subtract(const Duration(days: 1));
      h.doses.table.seed({
        ...DoseLogModel.fromLocalMap(
          (await localRow('dose_logs', ids.first))!,
        ).toJson(),
        'deleted_at': deletedAt.toIso8601String(),
      }, updatedAt: deletedAt);
      // The pull has already gone past that tombstone, so only the push
      // can act on it.
      await h.cursors.setPullKey('dose_logs', PullKey(h.core.horizon));

      await h.service.syncAll();

      expect(await localRow('dose_logs', ids.first), isNull);
      expect(await syncStatuses(ids.skip(1).toList()), [
        SyncStatus.synced,
        SyncStatus.synced,
      ]);
    });

    test('a dose taken while its batch is sent stays pending and goes out '
        'on the re-run', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 1);
      final release = Completer<void>();
      var held = false;
      h.doses.table.beforeCall = () async {
        if (held) return;
        held = true;
        await release.future;
      };

      final cycle = h.service.syncAll();
      await pumpEventQueue();
      await DoseLogLocalDatasource().updateStatus(
        ids.first,
        'taken',
        takenTime: h.clock.now(),
        syncStatus: SyncStatus.pendingUpdate,
      );
      release.complete();
      await cycle;

      expect(h.doses.table.rows[ids.first]!['status'], 'taken');
      final local = (await localRow('dose_logs', ids.first))!;
      expect(local['status'], 'taken');
      expect(local['sync_status'], SyncStatus.synced);
    });

    test('a failed batch leaves every row pending with backoff', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 1);
      h.doses.table.failIds.add(ids.last);

      final report = (await h.service.syncAll())!;

      expect(report.failures.map((f) => f.id), unorderedEquals(ids));
      expect(await syncStatuses(ids), everyElement(SyncStatus.pendingCreate));
      for (final id in ids) {
        expect(await h.failures.get('dose_logs', id), isNotNull);
      }
      expect(h.doses.table.rows, isEmpty);

      // Within the backoff nothing is sent; afterwards the batch goes out
      // and the failure records are cleared.
      h.doses.table.failIds.clear();
      final skipped = (await h.service.syncAll())!;
      expect(skipped.skippedBackoff, ids.length);
      expect(h.doses.table.rows, isEmpty);
      h.clock.advance(const Duration(hours: 1));
      await h.service.syncAll();
      expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
      for (final id in ids) {
        expect(await h.failures.get('dose_logs', id), isNull);
      }
    });
  });

  group('new dose logs the server refuses', () {
    Harness rejecting() => Harness(doseRows: RejectingDoseTable.new);

    test('a row the server rejects fails alone; the rest of its batch '
        'lands', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      final (_, ids) = await seedSchedule(durationDays: 1);
      remote.rejectIds.add(ids[1]);

      final report = (await h.service.syncAll())!;

      expect(report.failures.map((f) => f.id), [ids[1]]);
      expect(report.pushed, 2);
      expect(await syncStatuses(ids), [
        SyncStatus.synced,
        SyncStatus.pendingCreate,
        SyncStatus.synced,
      ]);
      expect(await h.failures.get('dose_logs', ids[0]), isNull);
      expect(await h.failures.get('dose_logs', ids[1]), isNotNull);
      expect(h.doses.table.rows.keys, unorderedEquals([ids[0], ids[2]]));
      // One batch, then each row alone.
      expect(remote.inserts, [
        ids,
        [ids[0]],
        [ids[1]],
        [ids[2]],
      ]);

      // After its backoff the bad row goes out alone, and fails alone.
      h.clock.advance(const Duration(hours: 1));
      final again = (await h.service.syncAll())!;
      expect(remote.inserts.last, [ids[1]]);
      expect(again.failures.map((f) => f.id), [ids[1]]);
      expect((await h.failures.get('dose_logs', ids[1]))!.count, 2);

      // Once the server takes it, it is synced like the others.
      remote.rejectIds.clear();
      h.clock.advance(const Duration(hours: 2));
      await h.service.syncAll();
      expect(remote.inserts.last, [ids[1]]);
      expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
      expect(await h.failures.get('dose_logs', ids[1]), isNull);
    });

    test('the doses of a prescription the server refused wait for it, '
        'without a request', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      remote.prescriptions = h.prescriptions.table;
      final db = await AppDatabase.instance.database;
      final (goodId, good) = await seedSchedule(durationDays: 1);
      final (badId, bad) = await seedSchedule(durationDays: 1);
      await db.update('medications', {'sync_status': SyncStatus.pendingCreate});
      await db.update('treatments', {'sync_status': SyncStatus.pendingCreate});
      await db.update('prescriptions', {
        'sync_status': SyncStatus.pendingCreate,
      });
      h.prescriptions.table.failIds.add(badId);

      final report = (await h.service.syncAll())!;

      expect(h.prescriptions.table.rows.keys, [goodId]);
      expect(await syncStatuses(good), everyElement(SyncStatus.synced));
      expect(await syncStatuses(bad), everyElement(SyncStatus.pendingCreate));
      expect(
        report.failures.map((f) => f.id),
        [badId],
        reason: 'the waiting doses are not failures of their own',
      );
      expect(remote.inserts, hasLength(1));
      expect(remote.inserts.single, unorderedEquals(good));

      // Once the prescription reaches the server, its doses follow.
      h.prescriptions.table.failIds.clear();
      h.clock.advance(const Duration(hours: 1));
      await h.service.syncAll();
      expect(await syncStatuses(bad), everyElement(SyncStatus.synced));
    });

    test('a row missing from the read-back stays pending with a failure '
        'record', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      final (_, ids) = await seedSchedule(durationDays: 1);
      remote.hideIds.add(ids.first);

      final report = (await h.service.syncAll())!;

      expect(report.failures.map((f) => f.id), [ids.first]);
      expect(await syncStatuses(ids), [
        SyncStatus.pendingCreate,
        SyncStatus.synced,
        SyncStatus.synced,
      ]);
      expect(await h.failures.get('dose_logs', ids.first), isNotNull);
    });

    test('a read-back without an answer leaves the rows pending with '
        'backoff', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      final (_, ids) = await seedSchedule(durationDays: 1);
      remote.readBackError = TimeoutException('no answer');

      final report = (await h.service.syncAll())!;

      expect(report.failures.map((f) => f.id), unorderedEquals(ids));
      expect(await syncStatuses(ids), everyElement(SyncStatus.pendingCreate));
      for (final id in ids) {
        expect(await h.failures.get('dose_logs', id), isNotNull);
      }
    });

    test('a recorded dose the server holds in a newer copy is adopted, not '
        'sent again', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final recordedAt = h.clock.now().subtract(const Duration(hours: 1));
      final intake = await seedDoseLog(
        db,
        seeded.prescriptionId,
        recordedAt,
        id: 'intake',
        status: 'taken',
        takenTime: recordedAt,
      );
      await db.update('dose_logs', {
        'updated_at': recordedAt.toIso8601String(),
        'sync_status': SyncStatus.pendingCreate,
      });
      // An earlier push landed without an answer, and another device has
      // since added a note.
      final local = DoseLogModel.fromLocalMap(
        (await localRow('dose_logs', intake))!,
      );
      h.doses.table.seed({
        ...local.toJson(),
        'notes': 'with food',
      }, updatedAt: h.clock.now().subtract(const Duration(minutes: 5)));

      await h.service.syncAll();

      expect(remote.upserted, isEmpty);
      expect(h.doses.table.rows[intake]!['notes'], 'with food');
      final row = (await localRow('dose_logs', intake))!;
      expect(row['notes'], 'with food');
      expect(row['sync_status'], SyncStatus.synced);
    });

    test('a batch that fails does not stop the batches after it', () async {
      final h = Harness();
      final (_, ids) = await seedSchedule(durationDays: 84);
      h.doses.table.failIds.add(ids.first);

      final report = (await h.service.syncAll())!;

      expect(h.doses.table.insertBatches, [100, 52]);
      expect(report.failures, hasLength(100));
      expect(report.pushed, 152);
      expect(
        await syncStatuses(ids.skip(100).toList()),
        everyElement(SyncStatus.synced),
      );
    });

    test('a network error while rows go out one by one stops there', () async {
      final h = rejecting();
      final remote = h.doses.rows as RejectingDoseTable;
      final (_, ids) = await seedSchedule(durationDays: 1);
      remote.rejectIds.add(ids[0]);
      // The second row's own request never gets an answer.
      h.doses.table.failIds.add(ids[1]);

      final report = (await h.service.syncAll())!;

      expect(remote.inserts, [
        ids,
        [ids[0]],
        [ids[1]],
      ]);
      expect(report.failures.map((f) => f.id), unorderedEquals(ids));
      expect(await syncStatuses(ids), everyElement(SyncStatus.pendingCreate));
    });
  });

  group('request timeout', () {
    test('a batch that lands but whose answer times out converges on the '
        'next attempt', () async {
      late HangingInsertTable remote;
      final h = Harness(
        requestTimeout: const Duration(milliseconds: 50),
        doseRows: (core) => remote = HangingInsertTable(core),
      );
      final (_, ids) = await seedSchedule(durationDays: 1);
      remote.hang = Completer<void>();

      final report = (await h.service.syncAll().timeout(
        const Duration(seconds: 5),
      ))!;

      expect(report.failures, hasLength(ids.length));
      expect(report.failures.first.error, contains('TimeoutException'));
      expect(await syncStatuses(ids), everyElement(SyncStatus.pendingCreate));
      // The insert did land; another device then took the first dose.
      expect(remote.rows, hasLength(ids.length));
      remote.rows[ids.first] = {
        ...remote.rows[ids.first]!,
        'status': 'taken',
        'updated_at': h.clock.now().toIso8601String(),
      };

      remote.hang!.complete();
      remote.hang = null;
      h.clock.advance(const Duration(hours: 1));
      final retry = (await h.service.syncAll())!;

      expect(retry.failures, isEmpty);
      expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
      expect((await localRow('dose_logs', ids.first))!['status'], 'taken');
      expect(remote.rows[ids.first]!['status'], 'taken');
    });

    test('an upsert that times out keeps the row pending', () async {
      final h = Harness(requestTimeout: const Duration(milliseconds: 50));
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-slow',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.pendingCreate,
      );
      final never = Completer<void>();
      h.meds.table.beforeCall = () => never.future;

      final report = (await h.service.syncAll().timeout(
        const Duration(seconds: 5),
      ))!;

      expect(report.failures.map((f) => f.table), contains('medications'));
      expect(
        (await localRow('medications', 'm-slow'))!['sync_status'],
        SyncStatus.pendingCreate,
      );
      expect(await h.failures.get('medications', 'm-slow'), isNotNull);
      expect(h.service.currentState, SyncState.partial);
    });

    test('a pull that times out keeps its cursor', () async {
      final h = Harness(requestTimeout: const Duration(milliseconds: 50));
      final cursor = PullKey(h.core.horizon);
      await h.cursors.setPullKey('dose_logs', cursor);
      final never = Completer<void>();
      h.doses.table.beforeCall = () => never.future;

      final report = (await h.service.syncAll().timeout(
        const Duration(seconds: 5),
      ))!;

      expect(
        report.failures.where((f) => f.table == 'dose_logs' && f.id == '*'),
        hasLength(1),
      );
      expect(await h.cursors.pullKey('dose_logs'), cursor);
    });
  });

  group('queued cycles', () {
    /// Holds the first call into the medications fake open until [gate]
    /// completes, so the test can call back into a running cycle.
    void gateFirstCall(Harness h, Completer<void> gate) {
      var held = false;
      h.meds.table.beforeCall = () async {
        if (held) return;
        held = true;
        await gate.future;
      };
    }

    test('a sync asked for during a cycle runs once more afterwards', () async {
      final h = Harness();
      final gate = Completer<void>();
      gateFirstCall(h, gate);

      final first = h.service.syncAll();
      await pumpEventQueue();
      expect(h.service.currentState, SyncState.syncing);

      // Requested mid-cycle: dropped before, queued now.
      expect(await h.service.syncAll(), isNull);

      gate.complete();
      await first;

      expect(h.meds.table.sinceCalls.length, 2);
    });

    test(
      'several requests during one cycle collapse into one re-run',
      () async {
        final h = Harness();
        final gate = Completer<void>();
        gateFirstCall(h, gate);

        final first = h.service.syncAll();
        await pumpEventQueue();
        expect(await h.service.syncAll(), isNull);
        expect(await h.service.syncAll(), isNull);
        expect(await h.service.syncAll(), isNull);

        gate.complete();
        await first;

        expect(h.meds.table.sinceCalls.length, 2);
      },
    );

    test('a queued re-run is dropped when the device goes offline', () async {
      final h = Harness();
      final gate = Completer<void>();
      gateFirstCall(h, gate);

      final first = h.service.syncAll();
      await pumpEventQueue();
      expect(await h.service.syncAll(), isNull); // queued
      h.online = false;

      gate.complete();
      await first;

      expect(h.meds.table.sinceCalls.length, 1);
      expect(h.service.currentState, isNot(SyncState.syncing));
    });

    test(
      'automatic re-runs stop after '
      '${SyncService.maxAutomaticReruns}; the row waits for the next sync',
      () async {
        late EditOnEveryPushTable remote;
        final h = Harness(
          medicationRows: (core) => remote = EditOnEveryPushTable(core),
        );
        await MedicationLocalDatasource().upsert(
          MedicationModel(
            id: 'm-busy',
            name: 'Local',
            quantity: 1,
            updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
          ),
          syncStatus: SyncStatus.pendingUpdate,
        );
        // The server has the row, so every push is an update.
        seedBusyRemote(h);

        await h.service.syncAll();

        const cycles = 1 + SyncService.maxAutomaticReruns;
        expect(remote.upserts, cycles);
        expect(h.meds.table.sinceCalls.length, cycles);
        expect(h.service.currentState, isNot(SyncState.syncing));
        final row = (await localRow('medications', 'm-busy'))!;
        expect(row['sync_status'], SyncStatus.pendingUpdate);
        expect(row['name'], 'edit $cycles');

        // The next request starts afresh, with its own allowance.
        await h.service.syncAll();
        expect(remote.upserts, 2 * cycles);
      },
    );

    test('a sync stopped at the cap retries once after a delay', () async {
      late EditOnEveryPushTable remote;
      final h = Harness(
        medicationRows: (core) => remote = EditOnEveryPushTable(core),
        capRetryDelay: const Duration(milliseconds: 40),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-busy',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // The server has the row, so every push is an update.
      seedBusyRemote(h);
      const cycles = 1 + SyncService.maxAutomaticReruns;

      await h.service.syncAll();
      expect(remote.upserts, cycles);
      expect(h.service.hasCapRetryScheduled, isTrue);

      // The retry runs on its own and stops at the cap too...
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.upserts, 2 * cycles);
      expect(h.service.currentState, isNot(SyncState.syncing));
      // ...without arming another one: no loop.
      expect(h.service.hasCapRetryScheduled, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.upserts, 2 * cycles);
    });

    test('a sync that finishes cancels a pending cap retry', () async {
      late EditOnEveryPushTable remote;
      final h = Harness(
        medicationRows: (core) =>
            remote = EditOnEveryPushTable(core, limit: cycles()),
        capRetryDelay: const Duration(milliseconds: 40),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-busy',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // The server has the row, so every push is an update.
      seedBusyRemote(h);
      await h.service.syncAll();
      expect(h.service.hasCapRetryScheduled, isTrue);

      // The edits have stopped: the next sync settles the row and leaves
      // nothing for the retry to do.
      await h.service.syncAll();
      expect(h.service.hasCapRetryScheduled, isFalse);
      final upserts = remote.upserts;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.upserts, upserts);
      expect(
        (await localRow('medications', 'm-busy'))!['sync_status'],
        SyncStatus.synced,
      );
    });

    test('dispose cancels a pending cap retry', () async {
      late EditOnEveryPushTable remote;
      final h = Harness(
        medicationRows: (core) => remote = EditOnEveryPushTable(core),
        capRetryDelay: const Duration(milliseconds: 40),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-busy',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // The server has the row, so every push is an update.
      seedBusyRemote(h);
      await h.service.syncAll();
      h.service.dispose();
      expect(h.service.hasCapRetryScheduled, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.upserts, 1 + SyncService.maxAutomaticReruns);
    });

    test('a cycle still running when the service is disposed stops there '
        'and arms no retry', () async {
      late EditOnEveryPushTable remote;
      final h = Harness(
        medicationRows: (core) => remote = EditOnEveryPushTable(core),
        capRetryDelay: const Duration(milliseconds: 40),
      );
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-busy',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      seedBusyRemote(h);
      final gate = Completer<void>();
      var held = false;
      h.meds.table.beforeCall = () async {
        if (held) return;
        held = true;
        await gate.future;
      };

      final cycle = h.service.syncAll();
      await pumpEventQueue();
      h.service.dispose();
      gate.complete();
      await cycle;

      expect(remote.upserts, 1, reason: 'no re-run after dispose');
      expect(h.service.hasCapRetryScheduled, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(remote.upserts, 1);
      expect(await h.service.syncAll(), isNull);
      expect(remote.upserts, 1);
    });

    test('a sync asked for during a force push runs once it ends', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-force',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.synced,
      );
      final gate = Completer<void>();
      gateFirstCall(h, gate); // force push's upsert

      final force = h.service.forcePush();
      await pumpEventQueue();
      // A write made meanwhile asks for a sync; it cannot run yet.
      expect(await h.service.syncAll(), isNull);
      expect(h.meds.table.sinceCalls, isEmpty);

      gate.complete();
      await force;

      // A force push does not pull; the pull is the requested sync's: a
      // page with the row, and the empty page that ends the table.
      expect(h.meds.table.sinceCalls, [null, isNotNull]);
    });

    test('a sync asked for during a force pull runs once it ends', () async {
      final h = Harness();
      final gate = Completer<void>();
      gateFirstCall(h, gate); // force pull's fetch

      final force = h.service.forcePull();
      await pumpEventQueue();
      expect(await h.service.syncAll(), isNull);

      gate.complete();
      await force;

      expect(h.meds.table.sinceCalls.length, 2);
    });

    test('a force push that leaves an edited row pending syncs it', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm-edit',
          name: 'Pushed',
          quantity: 1,
          updatedAt: h.clock.now(),
        ),
        syncStatus: SyncStatus.synced,
      );
      final db = await AppDatabase.instance.database;
      var held = false;
      h.meds.table.beforeCall = () async {
        if (held) return;
        held = true;
        // Edited while the force push sends the older copy.
        await db.update(
          'medications',
          {
            'name': 'Edited',
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': h.clock
                .now()
                .add(const Duration(seconds: 1))
                .toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: ['m-edit'],
        );
      };

      await h.service.forcePush();

      expect(h.meds.table.rows['m-edit']?['name'], 'Edited');
      final row = (await localRow('medications', 'm-edit'))!;
      expect(row['sync_status'], SyncStatus.synced);
    });

    test('force operations asked for during a cycle are not queued', () async {
      final h = Harness();
      final gate = Completer<void>();
      gateFirstCall(h, gate);

      final first = h.service.syncAll();
      await pumpEventQueue();
      expect(await h.service.forcePush(), isNull);
      expect(await h.service.forcePull(), isNull);

      gate.complete();
      await first;

      expect(h.meds.table.sinceCalls.length, 1);
    });
  });

  group('return to idle', () {
    /// Drives the fake clock forward in zero-length steps until [done] runs
    /// out of pending microtasks and same-instant timers — enough to finish a
    /// cycle against the in-memory database without firing the 2 s idle timer.
    void settle(FakeAsync async) {
      for (var i = 0; i < 50; i++) {
        async.elapse(Duration.zero);
      }
    }

    test('a finished cycle drops back to idle after 2 s', () async {
      await AppDatabase.instance.database; // open outside the fake zone
      fakeAsync((async) {
        final h = Harness();
        unawaited(h.service.syncAll());
        settle(async);
        expect(h.service.currentState, SyncState.success);

        async.elapse(const Duration(milliseconds: 1999));
        expect(h.service.currentState, SyncState.success);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.service.currentState, SyncState.idle);
        h.service.dispose();
      });
    });

    test(
      'a second cycle within 2 s is not dropped to idle by the first timer',
      () async {
        await AppDatabase.instance.database;
        fakeAsync((async) {
          final h = Harness();
          unawaited(h.service.syncAll());
          settle(async);
          expect(h.service.currentState, SyncState.success);

          // 1.5 s later — the first cycle's idle timer is still pending.
          async.elapse(const Duration(milliseconds: 1500));
          unawaited(h.service.syncAll());
          settle(async);
          expect(h.service.currentState, SyncState.success);

          // Now past 2 s from the *first* cycle: with an uncancelled timer
          // this is where the fresh result would be wiped to idle.
          async.elapse(const Duration(milliseconds: 600));
          expect(h.service.currentState, SyncState.success);

          // 2 s from the second cycle: idle, once.
          async.elapse(const Duration(milliseconds: 1400));
          expect(h.service.currentState, SyncState.idle);
          h.service.dispose();
        });
      },
    );

    test('dispose cancels the pending idle timer', () async {
      await AppDatabase.instance.database;
      fakeAsync((async) {
        final h = Harness();
        unawaited(h.service.syncAll());
        settle(async);
        expect(h.service.currentState, SyncState.success);
        h.service.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('auto-sync', () {
    test(
      'syncs once after an offline→online transition, not on repeated online events',
      () async {
        final controller = StreamController<bool>.broadcast();
        final h = Harness(online: controller);
        h.meds.table.seed(
          const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
        );
        h.service.startAutoSync(debounce: Duration.zero);

        controller.add(true); // already online → no transition
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.meds.table.sinceCalls, isEmpty);

        h.online = false;
        controller.add(false);
        h.online = true;
        controller.add(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // One pull: a page with the row, and the empty page after it.
        expect(h.meds.table.sinceCalls.length, 2);

        h.service.stopAutoSync();
        h.online = false;
        controller.add(false);
        h.online = true;
        controller.add(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.meds.table.sinceCalls.length, 2);
        await controller.close();
      },
    );
  });

  group('paged pull (the server answers at most 1000 rows)', () {
    test('a first pull of 2,500 dose rows stores all of them in one cycle, '
        'and the next pull starts at the horizon', () async {
      final h = Harness();
      await seedRemoteDoses(h, 2500, (_) => h.clock.now());
      final horizon = h.core.horizon;

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      expect(report.pulled, 2500);
      expect(await localDoseCount(), 2500);
      // Three full or short pages, and the empty one that ends the table.
      expect(h.doses.table.pageCalls, hasLength(4));
      expect(h.doses.table.pageCalls.map((c) => c.horizon).toSet(), {horizon});
      expect(await h.cursors.pullKey('dose_logs'), PullKey(horizon));
    });

    test('rows written in one transaction across a page boundary are each '
        'stored exactly once', () async {
      final h = Harness();
      final db = await AppDatabase.instance.database;
      final presc = await seedPrescription(db);
      // One insert of 1,500 rows is one transaction: they share a sync_xid.
      h.core.insertIfAbsent('dose_logs', [
        for (var i = 0; i < 1500; i++)
          DoseLogModel(
            id: 'shared-${i.toString().padLeft(4, '0')}',
            prescriptionId: presc.prescriptionId,
            scheduledTime: DateTime.utc(2026, 3).add(Duration(minutes: i)),
          ).toJson(),
      ]);
      await seedRemoteDoses(h, 300, (_) => h.clock.now());

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      // `pulled` counts every row applied: a row repeated across pages
      // would count twice, a skipped one not at all.
      expect(report.pulled, 1800);
      expect(await localDoseCount(), 1800);
      expect(h.doses.table.pageCalls, hasLength(3));
      final shared = h.doses.table.rows['shared-0999']!['sync_xid'] as int;
      expect(h.doses.table.pageCalls[1].after, PullKey(shared, 'shared-0999'));
    });

    test('1,500 generated doses all arrive on a first pull, and the next '
        'pull brings none of them again', () async {
      final h = Harness();
      await seedRemoteDoses(h, 1500, (_) => DateTime.utc(1970));

      final report = (await h.service.syncAll())!;
      expect(report.pulled, 1500);
      expect(await localDoseCount(), 1500);

      h.doses.table.pageCalls.clear();
      final second = (await h.service.syncAll())!;
      expect(second.pulled, 0);
      expect(h.doses.table.pageCalls, hasLength(1));
    });

    test('a failure on page 2 keeps page 1 and its key; the next cycle '
        'completes', () async {
      final h = Harness();
      final ids = await seedRemoteDoses(h, 2500, (_) => h.clock.now());
      var failed = false;
      h.doses.table.onPage = (call, after) {
        if (after != null && !failed) {
          failed = true;
          throw StateError('connection reset');
        }
      };

      final first = (await h.service.syncAll())!;

      expect(h.service.currentState, SyncState.partial);
      expect(
        first.failures.where((f) => f.table == 'dose_logs').map((f) => f.id),
        ['*'],
      );
      expect(await localDoseCount(), 1000);
      // Page 1 is the 1000 rows written first.
      expect(await localRow('dose_logs', ids[999]), isNotNull);
      expect(await localRow('dose_logs', ids[1000]), isNull);
      final pageOneEnd = PullKey(
        h.doses.table.rows[ids[999]]!['sync_xid'] as int,
        ids[999],
      );
      expect(await h.cursors.pullKey('dose_logs'), pageOneEnd);

      h.clock.advance(const Duration(minutes: 5));
      h.doses.table.pageCalls.clear();
      final second = (await h.service.syncAll())!;

      expect(second.failures, isEmpty);
      expect(await localDoseCount(), 2500);
      expect(h.doses.table.pageCalls.first.after, pageOneEnd);
      expect(await h.cursors.pullKey('dose_logs'), PullKey(h.core.horizon));
    });

    test('a row on page 2 that fails to apply holds the key at page 1 while '
        'later pages are still stored', () async {
      final h = Harness();
      final ids = await seedRemoteDoses(h, 2500, (_) => h.clock.now());
      // Its prescription is nowhere, so the local insert breaks the foreign
      // key and throws.
      h.doses.table.rows[ids[1500]]!['prescription_id'] = 'no-such';

      final report = (await h.service.syncAll())!;

      expect(
        report.failures.where((f) => f.table == 'dose_logs').map((f) => f.id),
        [ids[1500]],
      );
      expect(await localDoseCount(), 2499);
      expect(await localRow('dose_logs', ids[2499]), isNotNull);
      expect(
        await h.cursors.pullKey('dose_logs'),
        PullKey(h.doses.table.rows[ids[999]]!['sync_xid'] as int, ids[999]),
      );
    });

    test('a key above the server horizon (a restored server) starts the '
        'table over', () async {
      final h = Harness();
      await seedRemoteDoses(h, 3, (_) => h.clock.now());
      await h.cursors.setPullKey('dose_logs', PullKey(h.core.horizon + 500));

      final report = (await h.service.syncAll())!;

      expect(report.pulled, 3);
      expect(h.doses.table.pageCalls.first.after, isNull);
      expect(await h.cursors.pullKey('dose_logs'), PullKey(h.core.horizon));
    });

    test('a server that never ends a page stops the pull after the page '
        'limit', () async {
      final h = Harness(doseRows: EndlessPagesTable.new, maxPullPages: 3);
      await seedRemoteDoses(
        h,
        1200,
        (i) => DateTime.utc(2026, 3).add(Duration(seconds: i)),
      );

      final report = await h.service.syncAll().timeout(
        const Duration(seconds: 60),
      );

      expect(report, isNotNull);
      expect(h.doses.table.pageCalls, hasLength(3));
      expect(await localDoseCount(), 1000);
    });
  });

  group('pull repair after an upgrade', () {
    // What an older build left in the preferences: every table's cursor
    // where its newest-first, capped pull put it, and no repair marker.
    const tables = ['medications', 'treatments', 'prescriptions', 'dose_logs'];
    const doneKey = 'sync.pull_repair.done';

    Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    Future<SharedPreferences> upgradedPrefs(DateTime cursor) => prefsWith({
      for (final t in tables)
        'sync.last_pull_at.$t': cursor.toUtc().toIso8601String(),
    });

    Map<String, Object> snapshot(SharedPreferences prefs) => {
      for (final k in prefs.getKeys()) k: prefs.get(k)!,
    };

    /// A medication, treatment, prescription and three doses that only the
    /// server holds, stamped [stamp]: rows the old pull left behind its
    /// cursor. Returns their ids per table.
    Future<Map<String, List<String>>> seedServerOnly(
      Harness h,
      DateTime stamp,
    ) async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final doseIds = [
        for (var i = 0; i < 3; i++)
          await seedDoseLog(
            db,
            seeded.prescriptionId,
            DateTime(2026, 3, 1, 8).add(Duration(hours: 8 * i)),
            status: i == 0 ? 'taken' : 'pending',
          ),
      ];
      h.meds.table.seed(
        MedicationModel.fromLocalMap(
          (await localRow('medications', seeded.medicationId))!,
        ).toJson(),
        updatedAt: stamp,
      );
      h.treatments.table.seed(
        TreatmentModel.fromLocalMap(
          (await localRow('treatments', seeded.treatmentId))!,
        ).toJson(),
        updatedAt: stamp,
      );
      h.prescriptions.table.seed(
        PrescriptionModel.fromLocalMap(
          (await localRow('prescriptions', seeded.prescriptionId))!,
        ).toJson(),
        updatedAt: stamp,
      );
      for (final (i, id) in doseIds.indexed) {
        h.doses.table.seed(
          DoseLogModel.fromLocalMap(
            (await localRow('dose_logs', id))!,
          ).toJson(),
          updatedAt: stamp.add(Duration(seconds: i)),
        );
      }
      for (final id in doseIds) {
        await db.delete('dose_logs', where: 'id = ?', whereArgs: [id]);
      }
      await db.delete(
        'prescriptions',
        where: 'id = ?',
        whereArgs: [seeded.prescriptionId],
      );
      await db.delete(
        'treatments',
        where: 'id = ?',
        whereArgs: [seeded.treatmentId],
      );
      await db.delete(
        'medications',
        where: 'id = ?',
        whereArgs: [seeded.medicationId],
      );
      return {
        'medications': [seeded.medicationId],
        'treatments': [seeded.treatmentId],
        'prescriptions': [seeded.prescriptionId],
        'dose_logs': doseIds,
      };
    }

    Future<void> expectAllLocal(Map<String, List<String>> ids) async {
      for (final MapEntry(key: table, value: tableIds) in ids.entries) {
        for (final id in tableIds) {
          expect(await localRow(table, id), isNotNull, reason: '$table/$id');
        }
      }
    }

    Future<void> expectNoneLocal(Map<String, List<String>> ids) async {
      for (final MapEntry(key: table, value: tableIds) in ids.entries) {
        for (final id in tableIds) {
          expect(await localRow(table, id), isNull, reason: '$table/$id');
        }
      }
    }

    List<FakeSyncTable> remoteTables(Harness h) => [
      h.meds.table,
      h.treatments.table,
      h.prescriptions.table,
      h.doses.table,
    ];

    test('an upgraded device whose cursors sit past rows the server holds '
        'gets them on its first sync, and records the repair', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final oldCursor = clock.subtract(const Duration(hours: 1));
      final prefs = await upgradedPrefs(oldCursor);
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      final missing = await seedServerOnly(
        h,
        clock.subtract(const Duration(days: 2)),
      );
      // The same holds past one page: the old pull lost these too.
      final base = clock.subtract(const Duration(days: 3));
      final older = await seedRemoteDoses(
        h,
        1500,
        (i) => base.add(Duration(milliseconds: i)),
      );

      final report = (await h.service.syncAll())!;

      expect(report.failures, isEmpty);
      await expectAllLocal(missing);
      expect(await localDoseCount(), 1503);
      for (final id in [older.first, older.last]) {
        expect(await localRow('dose_logs', id), isNotNull);
      }
      expect(
        (await localRow('dose_logs', missing['dose_logs']!.first))!['status'],
        'taken',
      );
      for (final table in remoteTables(h)) {
        expect(table.pageCalls.first.after, isNull);
      }
      expect(h.doses.table.pageCalls, hasLength(3));
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
      // The keys are the full pull's own: the old timestamps are gone.
      expect(await h.cursors.pullKey('medications'), PullKey(h.core.horizon));
      expect(
        prefs.getKeys().where((k) => k.startsWith('sync.last_pull_at.')),
        isEmpty,
      );
    });

    test('the repair runs once: later syncs, and a restarted app, pull '
        'from the stored cursors', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final prefs = await upgradedPrefs(
        clock.subtract(const Duration(hours: 1)),
      );
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      await seedServerOnly(h, clock.subtract(const Duration(days: 2)));
      await h.service.syncAll();
      final cursor = await h.cursors.pullKey('medications');
      expect(cursor, isNotNull);

      h.clock.advance(const Duration(minutes: 5));
      await h.service.syncAll();
      expect(h.meds.table.pageCalls.last.after, cursor);

      // A restart: a new service over the same preferences and server.
      for (final table in remoteTables(h)) {
        table.pageCalls.clear();
      }
      final restarted = Harness(
        start: h.clock.now(),
        cursors: SyncCursorStore(prefs),
        server: h.server,
      );
      await restarted.service.syncAll();
      for (final table in remoteTables(restarted)) {
        expect(table.pageCalls.first.after, isNotNull);
      }
      expect(restarted.meds.table.pageCalls.single.after, cursor);
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
    });

    test('a sync that cannot run (offline, signed out) leaves the repair for '
        'a later sync', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final prefs = await upgradedPrefs(
        clock.subtract(const Duration(hours: 1)),
      );
      final before = snapshot(prefs);
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      final missing = await seedServerOnly(
        h,
        clock.subtract(const Duration(days: 2)),
      );

      h.online = false;
      expect(await h.service.syncAll(), isNull);
      h.online = true;
      h.userId = null;
      expect(await h.service.syncAll(), isNull);
      expect(snapshot(prefs), before);
      await expectNoneLocal(missing);

      h.userId = 'user-a';
      final report = (await h.service.syncAll())!;
      expect(report.failures, isEmpty);
      await expectAllLocal(missing);
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
    });

    test('a repair sync whose pull fails is not recorded; a later sync '
        'finishes it without pulling again what already arrived', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final prefs = await upgradedPrefs(
        clock.subtract(const Duration(hours: 1)),
      );
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      final missing = await seedServerOnly(
        h,
        clock.subtract(const Duration(days: 2)),
      );
      h.doses.table.throwOnFetch = StateError('connection reset');

      final first = (await h.service.syncAll())!;
      expect(h.service.currentState, SyncState.partial);
      expect(first.failures.map((f) => '${f.table}/${f.id}'), ['dose_logs/*']);
      expect(
        await localRow('medications', missing['medications']!.single),
        isNotNull,
      );
      for (final id in missing['dose_logs']!) {
        expect(await localRow('dose_logs', id), isNull);
      }
      expect(prefs.getInt(doneKey), isNull);
      final medCursor = await h.cursors.pullKey('medications');

      h.doses.table.throwOnFetch = null;
      h.clock.advance(const Duration(minutes: 5));
      final dosePages = h.doses.table.pageCalls.length;
      final medPages = h.meds.table.pageCalls.length;
      final second = (await h.service.syncAll())!;
      expect(second.failures, isEmpty);
      await expectAllLocal(missing);
      expect(h.doses.table.pageCalls[dosePages].after, isNull);
      expect(h.meds.table.pageCalls[medPages].after, medCursor);
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
    });

    test('a failed family fetch leaves the repair unfinished too', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final prefs = await upgradedPrefs(
        clock.subtract(const Duration(hours: 1)),
      );
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      // A membership row the client cannot read: the family fetch throws.
      h.family.members.rows['broken'] = {'id': 'broken', 'user_id': 'user-a'};

      final first = (await h.service.syncAll())!;
      expect(first.failures.map((f) => '${f.table}/${f.id}'), ['families/*']);
      expect(prefs.getInt(doneKey), isNull);

      h.family.members.rows.remove('broken');
      h.clock.advance(const Duration(minutes: 5));
      final second = (await h.service.syncAll())!;
      expect(second.failures, isEmpty);
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
    });

    test('local-only mode leaves the cursors and the marker alone', () async {
      final prefs = await upgradedPrefs(DateTime.utc(2026, 3, 4, 11));
      final before = snapshot(prefs);
      final service = SyncService(
        medicationLocal: MedicationLocalDatasource(),
        medicationRemote: null,
        syncState: null,
        treatmentLocal: TreatmentLocalDatasource(),
        treatmentRemote: null,
        prescriptionLocal: PrescriptionLocalDatasource(),
        prescriptionRemote: null,
        doseLogLocal: DoseLogLocalDatasource(),
        doseLogRemote: null,
        familyLocal: FamilyLocalDatasource(),
        familyRemote: null,
        cursors: SyncCursorStore(prefs),
        isOnline: () => true,
        currentUserId: () => 'user-a',
        onlineStream: const Stream<bool>.empty(),
      );
      addTearDown(service.dispose);

      expect(await service.syncAll(), isNull);
      expect(await service.forcePush(), isNull);
      expect(snapshot(prefs), before);
    });

    test(
      'a device that finished the first repair runs this one once more',
      () async {
        final clock = DateTime.utc(2026, 3, 4, 12);
        final prefs = await prefsWith({
          for (final t in tables)
            'sync.last_pull_at.$t': clock
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
          'sync.pull_repair.reset': 1,
          'sync.pull_repair.done': 1,
        });
        final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
        final missing = await seedServerOnly(
          h,
          clock.subtract(const Duration(days: 2)),
        );

        await h.service.syncAll();

        await expectAllLocal(missing);
        expect(h.meds.table.pageCalls.first.after, isNull);
        expect(prefs.getInt(doneKey), 2);
      },
    );

    test('a fresh install records the repair with its first pull', () async {
      final prefs = await prefsWith({});
      final h = Harness(cursors: SyncCursorStore(prefs));
      h.meds.table.seed(
        const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
      );

      final xidA = h.meds.table.rows['a']!['sync_xid'] as int;
      await h.service.syncAll();
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
      final cursor = await h.cursors.pullKey('medications');

      h.clock.advance(const Duration(minutes: 5));
      await h.service.syncAll();
      expect(h.meds.table.pageCalls.map((c) => c.after), [
        null,
        PullKey(xidA, 'a'),
        cursor,
      ]);
    });

    test('the repair pull keeps local changes still waiting to be pushed, '
        'and rows the server does not have', () async {
      final clock = DateTime.utc(2026, 3, 4, 12);
      final prefs = await upgradedPrefs(
        clock.subtract(const Duration(hours: 1)),
      );
      final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
      final medLocal = MedicationLocalDatasource();
      // An edit made after the server's copy, waiting out a backoff.
      h.meds.table.seed(
        const MedicationModel(
          id: 'm-edit',
          name: 'Server',
          quantity: 1,
        ).toJson(),
        updatedAt: clock.subtract(const Duration(days: 2)),
      );
      await medLocal.upsert(
        MedicationModel(
          id: 'm-edit',
          name: 'Local',
          quantity: 1,
          updatedAt: clock.subtract(const Duration(days: 1)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      await h.failures.recordFailure('medications', 'm-edit', clock);
      // A delete waiting out a backoff, of a row the server still has.
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final treatment = TreatmentModel.fromLocalMap(
        (await localRow('treatments', seeded.treatmentId))!,
      );
      h.treatments.table.seed(
        treatment.toJson(),
        updatedAt: clock.subtract(const Duration(days: 2)),
      );
      await db.update(
        'treatments',
        {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?',
        whereArgs: [treatment.id],
      );
      await h.failures.recordFailure('treatments', treatment.id, clock);
      // A synced row the server does not have: nothing is wiped.
      await medLocal.upsert(
        const MedicationModel(id: 'm-local', name: 'Only here', quantity: 2),
        syncStatus: SyncStatus.synced,
      );

      final report = (await h.service.syncAll())!;

      expect(report.skippedBackoff, 2);
      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
      expect(h.meds.table.pageCalls.first.after, isNull);
      final edited = (await localRow('medications', 'm-edit'))!;
      expect(edited['name'], 'Local');
      expect(edited['sync_status'], SyncStatus.pendingUpdate);
      expect(
        (await localRow('treatments', treatment.id))!['sync_status'],
        SyncStatus.pendingDelete,
      );
      expect((await localRow('medications', 'm-local'))!['name'], 'Only here');
      expect(h.meds.table.get('m-edit')!['name'], 'Server');
    });
  });
}
