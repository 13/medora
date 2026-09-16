import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class Harness {
  Harness({
    DateTime? start,
    StreamController<bool>? online,
    FamilyLocalDatasource? familyLocal,
    FakeMedicationRemote Function(DateTime Function() clock)? medicationRemote,
  }) : clock = TestClock(start ?? DateTime.utc(2026, 3, 4, 12)) {
    meds = (medicationRemote ?? FakeMedicationRemote.new)(clock.now);
    treatments = FakeTreatmentRemote(clock.now);
    prescriptions = FakePrescriptionRemote(clock.now);
    doses = FakeDoseLogRemote(clock.now);
    family = FakeFamilyRemote(clock.now);
    cursors = SyncCursorStore.inMemory();
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
      cursors: cursors,
      failures: failures,
      isOnline: () => this.online,
      currentUserId: () => userId,
      onlineStream: online?.stream ?? const Stream<bool>.empty(),
      now: clock.now,
    );
  }

  final TestClock clock;
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

/// A medication server whose every upsert is joined by a local edit of the
/// same row, as a writer that touches the row on every cycle would do: the
/// cycle always finds the row changed after its push. Stops after [limit]
/// edits so a missing cap fails the test instead of hanging it.
class EditOnEveryPushRemote extends FakeMedicationRemote {
  EditOnEveryPushRemote(super.clock, {this.limit = 50});

  final int limit;
  int upserts = 0;

  @override
  Future<DateTime?> upsertMedication(MedicationModel model) async {
    upserts++;
    if (upserts <= limit) {
      final db = await AppDatabase.instance.database;
      final row = (await localRow('medications', model.id))!;
      final stamp = DateTime.parse(row['updated_at'] as String);
      await db.update(
        'medications',
        {
          'name': 'edit $upserts',
          'updated_at': stamp
              .add(const Duration(milliseconds: 1))
              .toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [model.id],
      );
    }
    return super.upsertMedication(model);
  }
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

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  SyncService makeLocalOnly() => SyncService(
    medicationLocal: MedicationLocalDatasource(),
    medicationRemote: null,
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

    test(
      'a stale pending update is not pushed and the remote copy wins',
      () async {
        final h = Harness();
        // Local edit at T+10min, remote edit at T+20min. No failIds trick:
        // the push itself must notice the remote row is newer and stand down.
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

        expect(report.skippedStale, 1);
        expect(report.pushed, 0);
        expect(report.failures, isEmpty);
        expect(h.service.currentState, SyncState.success);
        expect(h.meds.table.rows['m9']?['name'], 'Remote');
        final row = await localRow('medications', 'm9');
        expect(row?['name'], 'Remote');
        expect(row?['sync_status'], SyncStatus.synced);
      },
    );

    test(
      'a stale skipped push rewinds the cursor so the pull refetches the row',
      () async {
        final h = Harness();
        final t = h.clock.now();
        // The server stamped the winning remote row at T+20 …
        h.meds.table.seed(
          const MedicationModel(
            id: 'm9b',
            name: 'Remote',
            quantity: 1,
          ).toJson(),
          updatedAt: t.add(const Duration(minutes: 20)),
        );
        // … but this device's cursor already sits past it: `updated_at` is
        // server-clock on the remote side and device-clock locally, so a
        // delta pull asking for `> cursor` would never return the row again.
        await h.cursors.setLastPullAt(
          'medications',
          t.add(const Duration(minutes: 30)),
        );
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

        expect(report.skippedStale, 1);
        expect(report.failures, isEmpty);
        final row = await localRow('medications', 'm9b');
        expect(
          row?['name'],
          'Remote',
          reason: 'the skipped row must be replaced by the pull it relies on',
        );
        expect(row?['sync_status'], SyncStatus.synced);
      },
    );

    test('a pending update newer than the remote row is pushed', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        MedicationModel(
          id: 'm10',
          name: 'Local',
          quantity: 1,
          updatedAt: h.clock.now().add(const Duration(minutes: 20)),
        ),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm10', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(minutes: 5)),
      );

      final report = (await h.service.syncAll())!;

      expect(report.skippedStale, 0);
      expect(report.pushed, 1);
      expect(h.meds.table.rows['m10']?['name'], 'Local');
      expect((await localRow('medications', 'm10'))?['name'], 'Local');
    });

    test(
      'a pending create and a tombstone push even against a newer remote row',
      () async {
        final h = Harness();
        final local = MedicationLocalDatasource();
        // pending_create whose id already exists remotely, newer.
        await local.upsert(
          MedicationModel(
            id: 'm11',
            name: 'Local',
            quantity: 1,
            updatedAt: h.clock.now(),
          ),
          syncStatus: SyncStatus.pendingCreate,
        );
        h.meds.table.seed(
          const MedicationModel(
            id: 'm11',
            name: 'Remote',
            quantity: 1,
          ).toJson(),
          updatedAt: h.clock.now().add(const Duration(hours: 1)),
        );
        // pending_delete against a newer remote row.
        h.meds.table.seed(
          const MedicationModel(
            id: 'm12',
            name: 'Doomed',
            quantity: 1,
          ).toJson(),
          updatedAt: h.clock.now().add(const Duration(hours: 1)),
        );
        await local.upsert(
          const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1),
          syncStatus: SyncStatus.synced,
        );
        await local.markDeleted('m12');

        final report = (await h.service.syncAll())!;

        expect(report.skippedStale, 0);
        expect(h.meds.table.rows['m11']?['name'], 'Local');
        expect(h.meds.table.rows['m12']?['deleted_at'], isNotNull);
      },
    );

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

      expect(report.skippedStale, 0);
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
      expect(
        report.pulled,
        greaterThanOrEqualTo(2),
      ); // 'a' comes back from the fake + 't'
      expect(report.failures, isEmpty);
      expect(report.finishedAt, isNotNull);
      expect(h.service.lastReport, same(report));
      expect(h.service.currentState, SyncState.success);
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

  group('delta pull', () {
    test(
      'first pull is full, second pull asks since the newest updated_at minus 1s',
      () async {
        final h = Harness();
        h.meds.table.seed(
          const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
        );
        await h.service.syncAll();
        expect(h.meds.table.sinceCalls, [null]);
        final cursor = await h.cursors.lastPullAt('medications');
        expect(
          cursor,
          h.clock.now().toUtc().subtract(const Duration(seconds: 1)),
        );

        h.clock.advance(const Duration(minutes: 5));
        h.meds.table.seed(
          const MedicationModel(id: 'b', name: 'B', quantity: 1).toJson(),
        );
        h.service.debugSetStateForTest(SyncState.idle);
        final report = (await h.service.syncAll())!;
        expect(h.meds.table.sinceCalls.last, cursor);
        // 'a's own updated_at sits exactly at cursor + 1s (the deliberate overlap),
        // so it is legitimately re-fetched and idempotently re-applied alongside
        // the genuinely new 'b' — the 1 s overlap always re-includes the row it
        // was computed from, by construction, regardless of elapsed wall time.
        expect(report.pulled, 2);
        expect((await localRow('medications', 'b'))?['name'], 'B');
      },
    );

    test('force pull clears cursors and pulls everything again', () async {
      final h = Harness();
      h.meds.table.seed(
        const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
      );
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      await h.service.forcePull();
      expect(h.meds.table.sinceCalls.last, isNull);
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
      final before = await h.cursors.lastPullAt('medications');
      h.service.debugSetStateForTest(SyncState.idle);
      // Make apply fail for a new row: seed a row whose JSON breaks fromJson.
      h.meds.table.rows['broken'] = {
        'id': 'broken',
        'updated_at': h.clock
            .now()
            .add(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      };
      final report = (await h.service.syncAll())!;
      expect(
        report.failures.where((f) => f.table == 'medications'),
        isNotEmpty,
      );
      expect(await h.cursors.lastPullAt('medications'), before);
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
      expect(await h.cursors.lastPullAt('prescriptions'), isNull);
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
      required FakeRemoteTable remote,
      required String column,
      required Future<String> Function(Database db) seed,
      required Map<String, dynamic> Function(Map<String, dynamic> row) toServer,
    }) async {
      final db = await AppDatabase.instance.database;
      final id = await seed(db);
      final pushedAt = h.clock.now().subtract(const Duration(minutes: 2));
      await db.update(
        table,
        {
          column: 'pushed copy',
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': pushedAt.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      remote.seed({
        ...toServer((await localRow(table, id))!),
        column: 'server copy',
      }, updatedAt: h.clock.now().subtract(const Duration(hours: 1)));

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
        late EditOnEveryPushRemote remote;
        final h = Harness(
          medicationRemote: (clock) => remote = EditOnEveryPushRemote(clock),
        );
        await MedicationLocalDatasource().upsert(
          MedicationModel(
            id: 'm-busy',
            name: 'Local',
            quantity: 1,
            updatedAt: h.clock.now(),
          ),
          syncStatus: SyncStatus.pendingUpdate,
        );

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

      // A force push does not pull; the pull is the requested sync's.
      expect(h.meds.table.sinceCalls.length, 1);
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
        expect(h.meds.table.sinceCalls.length, 1);

        h.service.stopAutoSync();
        h.online = false;
        controller.add(false);
        h.online = true;
        controller.add(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(h.meds.table.sinceCalls.length, 1);
        await controller.close();
      },
    );
  });
}
