/// The medication, prescription and dose-log write paths against a running
/// sync cycle: a write made while the cycle pushes an older copy of the same
/// row must survive on both sides.
///
/// The fake server stamps `updated_at` with its own clock on every update, as
/// the `update_updated_at` trigger does.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/services/sync_service.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class _Rig {
  late final FakeServerCore core;
  _Rig() {
    DateTime serverNow() => DateTime.now().toUtc();
    core = FakeServerCore(serverNow);
    meds = FakeMedicationRemote(core);
    prescriptions = FakePrescriptionRemote(core);
    doses = FakeDoseLogRemote(core);
    service = SyncService(
      medicationLocal: medicationLocal,
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: FakeTreatmentRemote(core),
      prescriptionLocal: prescriptionLocal,
      prescriptionRemote: prescriptions,
      doseLogLocal: doseLogLocal,
      doseLogRemote: doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: FakeFamilyRemote(serverNow),
      syncState: FakeSyncState(core),
      isOnline: () => true,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
    );
    medicationRepo = MedicationRepositoryImpl(
      localDatasource: medicationLocal,
      requestSync: _requestSync,
    );
    prescriptionRepo = PrescriptionRepositoryImpl(
      localDatasource: prescriptionLocal,
      requestSync: _requestSync,
    );
    doseLogRepo = DoseLogRepositoryImpl(
      localDatasource: doseLogLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
    );
  }

  final medicationLocal = MedicationLocalDatasource();
  final prescriptionLocal = PrescriptionLocalDatasource();
  final doseLogLocal = DoseLogLocalDatasource();
  late final FakeMedicationRemote meds;
  late final FakePrescriptionRemote prescriptions;
  late final FakeDoseLogRemote doses;
  late final SyncService service;
  late final MedicationRepositoryImpl medicationRepo;
  late final PrescriptionRepositoryImpl prescriptionRepo;
  late final DoseLogRepositoryImpl doseLogRepo;
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
    _requests.add(cycle);
    return cycle;
  }

  /// Completes once every sync cycle asked for has finished, queued re-runs
  /// included.
  Future<void> idle() async {
    await pumpEventQueue();
    while (_requests.isNotEmpty) {
      final pending = List.of(_requests);
      _requests.clear();
      await Future.wait(pending);
      await pumpEventQueue();
    }
  }

  /// Runs a sync cycle whose first call into [table] (its push of the
  /// pending row) is held until [write] has run.
  Future<void> writeWhileCyclePushes(
    FakeSyncTable table,
    Future<void> Function() write,
  ) async {
    final release = Completer<void>();
    final started = Completer<void>();
    var held = false;
    table.beforeCall = () async {
      if (held) return;
      held = true;
      started.complete();
      await release.future;
    };
    final cycle = service.syncAll();
    await started.future;
    await write();
    await pumpEventQueue();
    release.complete();
    await cycle;
    await idle();
  }
}

Future<Map<String, dynamic>> _localRow(String table, String id) async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
  return rows.single;
}

/// Marks the local row [id] as changed offline, [values] applied, stamped
/// [at].
Future<void> _pendingOffline(
  String table,
  String id,
  Map<String, Object?> values,
  DateTime at,
) async {
  final db = await AppDatabase.instance.database;
  await db.update(
    table,
    {
      ...values,
      'sync_status': SyncStatus.pendingUpdate,
      'updated_at': at.toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final longAgo = DateTime.utc(2026, 3, 2, 8);
  final offline = DateTime.now().subtract(const Duration(minutes: 5));

  group('a write made while the cycle pushes an older copy survives', () {
    test(
      'prescriptions: a reactivation after an offline deactivation',
      () async {
        final r = _Rig();
        final db = await AppDatabase.instance.database;
        final id = (await seedPrescription(db)).prescriptionId;
        r.prescriptions.table.seed(
          PrescriptionModel.fromLocalMap(
            await _localRow('prescriptions', id),
          ).toJson(),
          updatedAt: longAgo,
        );
        await _pendingOffline('prescriptions', id, {'is_active': 0}, offline);

        await r.writeWhileCyclePushes(
          r.prescriptions.table,
          () => r.prescriptionRepo.reactivatePrescription(id),
        );

        expect(r.prescriptions.table.rows[id]!['is_active'], isTrue);
        final local = await _localRow('prescriptions', id);
        expect(local['is_active'], 1);
        expect(local['sync_status'], SyncStatus.synced);
      },
    );

    test('medications: an edit after an offline edit', () async {
      final r = _Rig();
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).medicationId;
      r.meds.table.seed(
        MedicationModel.fromLocalMap(
          await _localRow('medications', id),
        ).toJson(),
        updatedAt: longAgo,
      );
      await _pendingOffline('medications', id, {'name': 'offline'}, offline);

      await r.writeWhileCyclePushes(r.meds.table, () async {
        final current = (await r.medicationRepo.getMedicationById(
          id,
        )).dataOrNull!;
        await r.medicationRepo.updateMedication(
          current.copyWith(name: 'latest'),
        );
      });

      expect(r.meds.table.rows[id]!['name'], 'latest');
      final local = await _localRow('medications', id);
      expect(local['name'], 'latest');
      expect(local['sync_status'], SyncStatus.synced);
    });

    test('medications: a dose taken while the cycle sends an offline one is '
        'counted once', () async {
      final r = _Rig();
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).medicationId; // quantity 10
      r.meds.table.seed(
        MedicationModel.fromLocalMap(
          await _localRow('medications', id),
        ).toJson(),
        updatedAt: longAgo,
      );
      // This device pulled that copy.
      await r.service.syncAll();
      await r.idle();
      // Two tablets taken offline: waiting as one stock change.
      await db.transaction((txn) async {
        await txn.update(
          'medications',
          {'quantity': 8},
          where: 'id = ?',
          whereArgs: [id],
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          StockOp(
            opId: 'offline-op',
            medicationId: id,
            delta: -2,
            createdAt: offline,
          ),
        );
      });

      await r.writeWhileCyclePushes(
        r.meds.table,
        () => r.medicationRepo.updateQuantity(id, -1),
      );

      expect(r.meds.table.rows[id]!['quantity'], 7);
      final local = await _localRow('medications', id);
      expect(local['quantity'], 7);
      expect(local['sync_status'], SyncStatus.synced);
      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
    });

    test('medications: a dose taken while the stock change before it is on '
        'its way is counted once', () async {
      final r = _Rig();
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).medicationId; // quantity 10
      r.meds.table.seed(
        MedicationModel.fromLocalMap(
          await _localRow('medications', id),
        ).toJson(),
        updatedAt: longAgo,
      );
      await r.service.syncAll();
      await r.idle();
      await r.medicationRepo.updateQuantity(id, -2);
      final release = Completer<void>();
      final started = Completer<void>();
      r.meds.stock.beforeCall = (op) async {
        if (started.isCompleted) return;
        started.complete();
        await release.future;
      };
      final cycle = r.service.syncAll();
      await started.future;
      await r.medicationRepo.updateQuantity(id, -1);
      release.complete();
      await cycle;
      await r.idle();

      expect(r.meds.table.rows[id]!['quantity'], 7);
      expect((await _localRow('medications', id))['quantity'], 7);
      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
    });

    test('dose logs: taken after an offline skip', () async {
      final r = _Rig();
      final db = await AppDatabase.instance.database;
      final id = await seedDoseLog(
        db,
        (await seedPrescription(db)).prescriptionId,
        DateTime(2026, 3, 1, 8),
      );
      r.doses.table.seed(
        DoseLogModel.fromLocalMap(await _localRow('dose_logs', id)).toJson(),
        updatedAt: longAgo,
      );
      await _pendingOffline('dose_logs', id, {'status': 'skipped'}, offline);

      await r.writeWhileCyclePushes(
        r.doses.table,
        () => r.doseLogRepo.markDoseTaken(id),
      );

      expect(r.doses.table.rows[id]!['status'], 'taken');
      final local = await _localRow('dose_logs', id);
      expect(local['status'], 'taken');
      expect(local['sync_status'], SyncStatus.synced);
    });
  });

  group('writes reach the server through the sync cycle', () {
    test('a medication added, restocked and deleted', () async {
      final r = _Rig();
      await r.medicationRepo.addMedication(
        const MedicationModel(id: 'm1', name: 'Moment', quantity: 3).toDomain(),
      );
      await r.idle();
      expect(r.meds.table.rows['m1']!['name'], 'Moment');

      await r.medicationRepo.updateQuantity('m1', 2);
      await r.idle();
      expect(r.meds.table.rows['m1']!['quantity'], 5);

      await r.medicationRepo.archiveMedication('m1');
      await r.idle();
      expect(r.meds.table.rows['m1']!['is_archived'], isTrue);

      await r.medicationRepo.deleteMedication('m1');
      await r.idle();
      expect(r.meds.table.rows['m1']!['deleted_at'], isNotNull);
      expect(
        await (await AppDatabase.instance.database).query('medications'),
        isEmpty,
      );
    });

    test('generated dose logs and a prescription change', () async {
      final r = _Rig();
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db, durationDays: 1)).prescriptionId;

      final generated = await r.doseLogRepo.generateDoseLogsForPrescription(id);
      await r.idle();
      expect(generated.dataOrNull, hasLength(3));
      expect(r.doses.table.rows, hasLength(3));

      await r.prescriptionRepo.deactivatePrescription(id);
      await r.idle();
      expect(r.prescriptions.table.rows[id]!['is_active'], isFalse);
      expect(
        (await _localRow('prescriptions', id))['sync_status'],
        SyncStatus.synced,
      );
    });
  });
}
