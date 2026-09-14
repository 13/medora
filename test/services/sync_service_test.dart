import 'dart:async';

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
import 'package:medora/services/sync_service.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class Harness {
  Harness({DateTime? start, StreamController<bool>? online})
    : clock = TestClock(start ?? DateTime.utc(2026, 3, 4, 12)) {
    meds = FakeMedicationRemote(clock.now);
    treatments = FakeTreatmentRemote(clock.now);
    prescriptions = FakePrescriptionRemote(clock.now);
    doses = FakeDoseLogRemote(clock.now);
    family = FakeFamilyRemote(clock.now);
    cursors = SyncCursorStore.inMemory();
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: family,
      cursors: cursors,
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
  late final SyncService service;
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
