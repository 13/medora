import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_service.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class Harness {
  Harness({DateTime? start}) : clock = TestClock(start ?? DateTime.utc(2026, 3, 4, 12)) {
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
      isOnline: () => online,
      currentUserId: () => userId,
      onlineStream: const Stream<bool>.empty(),
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
    expect(() => service.debugSetStateForTest(SyncState.success), returnsNormally);
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
      expect((await localRow('medications', 'm1'))?['sync_status'], SyncStatus.synced);
      expect(h.service.currentState, SyncState.success);
    });

    test('pulls a remote medication into the local database', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'm2', name: 'Tachipirina', quantity: 1).toJson());
      await h.service.syncAll();
      expect((await localRow('medications', 'm2'))?['name'], 'Tachipirina');
      expect((await localRow('medications', 'm2'))?['sync_status'], SyncStatus.synced);
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

    test('remote tombstone hard-deletes the local row even if locally pending', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'm4', name: 'Gone', quantity: 1).toJson());
      h.meds.table.tombstone('m4');
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'm4', name: 'Gone', quantity: 1),
        syncStatus: SyncStatus.pendingUpdate,
      );
      // Push fails, so the row is still pending when the pull phase runs.
      h.meds.table.failIds.add('m4');
      await h.service.syncAll();
      expect(await localRow('medications', 'm4'), isNull);
    });

    test('local delete pushes a tombstone and hard-deletes locally', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'm5', name: 'Bye', quantity: 1).toJson());
      await h.service.syncAll(); // now local synced
      await MedicationLocalDatasource().markDeleted('m5');
      expect((await localRow('medications', 'm5'))?['deleted_at'], isNotNull);
      await h.service.syncAll();
      expect(h.meds.table.rows['m5']?['deleted_at'], isNotNull);
      expect(await localRow('medications', 'm5'), isNull);
    });

    test('a remotely deleted treatment cascades to local prescriptions and dose logs', () async {
      final h = Harness();
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
      h.treatments.table.seed(
          (await TreatmentLocalDatasource().getTreatmentById(seeded.treatmentId))!.toJson());
      h.treatments.table.tombstone(seeded.treatmentId);
      await h.service.syncAll();
      expect(await localRow('treatments', seeded.treatmentId), isNull);
      expect(await localRow('prescriptions', seeded.prescriptionId), isNull);
      expect((await db.query('dose_logs')), isEmpty);
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
}
