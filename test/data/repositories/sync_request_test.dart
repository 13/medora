/// The medication, prescription and dose-log repositories write locally and
/// then ask for a sync cycle, which is their only push path.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Records the row's `sync_status` each time a sync is asked for: the cycle
/// pushes whatever is pending when it runs, so the local write must be
/// complete before the request.
class _Requests {
  _Requests(this.table);

  final String table;
  String? id;
  final List<String?> statuses = [];
  Object? failWith;

  Future<void> call() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    statuses.add(rows.isEmpty ? null : rows.single['sync_status'] as String?);
    final failure = failWith;
    if (failure != null) throw failure;
  }
}

Future<String?> _status(String table, String id) async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
  return rows.isEmpty ? null : rows.single['sync_status'] as String?;
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  const pendingCreate = SyncStatus.pendingCreate;
  const pendingUpdate = SyncStatus.pendingUpdate;
  const pendingDelete = SyncStatus.pendingDelete;

  group('medications', () {
    test('every write asks for one sync after the local write', () async {
      final requests = _Requests('medications')..id = 'm1';
      final repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
        requestSync: requests.call,
      );

      await repo.addMedication(
        const Medication(id: 'm1', name: 'Moment', quantity: 3),
      );
      await pumpEventQueue();
      final added = (await repo.getMedicationById('m1')).dataOrNull!;
      await repo.updateMedication(added.copyWith(name: 'Moment Act'));
      await pumpEventQueue();
      await repo.updateQuantity('m1', -1);
      await pumpEventQueue();
      await repo.archiveMedication('m1');
      await pumpEventQueue();
      await repo.unarchiveMedication('m1');
      await pumpEventQueue();
      await repo.deleteMedication('m1');
      await pumpEventQueue();

      expect(requests.statuses, [
        pendingCreate,
        pendingUpdate,
        pendingUpdate,
        pendingUpdate,
        pendingUpdate,
        pendingDelete,
      ]);
    });

    test('a failed request does not fail the write', () async {
      final requests = _Requests('medications')
        ..id = 'm1'
        ..failWith = StateError('offline');
      final repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
        requestSync: requests.call,
      );

      final result = await repo.addMedication(
        const Medication(id: 'm1', name: 'Moment', quantity: 3),
      );
      await pumpEventQueue();

      expect(result.isSuccess, isTrue);
      expect(await _status('medications', 'm1'), pendingCreate);
    });

    test('a quantity change on a missing medication asks for none', () async {
      final requests = _Requests('medications');
      final repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
        requestSync: requests.call,
      );

      await repo.updateQuantity('missing', 1);
      await pumpEventQueue();

      expect(requests.statuses, isEmpty);
    });
  });

  group('prescriptions', () {
    test('every write asks for one sync after the local write', () async {
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).prescriptionId;
      final requests = _Requests('prescriptions')..id = id;
      final repo = PrescriptionRepositoryImpl(
        localDatasource: PrescriptionLocalDatasource(),
        requestSync: requests.call,
      );

      final existing = (await repo.getPrescriptionById(id)).dataOrNull!;
      await repo.updatePrescription(existing.copyWith(notes: 'after meals'));
      await pumpEventQueue();
      await repo.deactivatePrescription(id);
      await pumpEventQueue();
      await repo.reactivatePrescription(id);
      await pumpEventQueue();
      await repo.deletePrescription(id);
      await pumpEventQueue();

      expect(requests.statuses, [
        pendingUpdate,
        pendingUpdate,
        pendingUpdate,
        pendingDelete,
      ]);

      final copy = existing.copyWith(id: 'p-new');
      requests.id = 'p-new';
      await repo.addPrescription(copy);
      await pumpEventQueue();
      expect(requests.statuses.last, pendingCreate);
      expect(requests.statuses, hasLength(5));
    });

    test(
      'a request that throws synchronously does not fail the write',
      () async {
        final db = await AppDatabase.instance.database;
        final id = (await seedPrescription(db)).prescriptionId;
        final repo = PrescriptionRepositoryImpl(
          localDatasource: PrescriptionLocalDatasource(),
          requestSync: () => throw StateError('provider disposed'),
        );

        final result = await repo.deactivatePrescription(id);

        expect(result.isSuccess, isTrue);
        expect(await _status('prescriptions', id), pendingUpdate);
      },
    );
  });

  group('dose logs', () {
    test('every write asks for one sync after the local write', () async {
      final db = await AppDatabase.instance.database;
      final prescriptionId = (await seedPrescription(db)).prescriptionId;
      final id = await seedDoseLog(db, prescriptionId, DateTime(2026, 3, 1, 8));
      final requests = _Requests('dose_logs')..id = id;
      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
        requestSync: requests.call,
      );

      await repo.markDoseTaken(id);
      await pumpEventQueue();
      await repo.markDosePending(id);
      await pumpEventQueue();
      await repo.markDoseSkipped(id);
      await pumpEventQueue();
      await repo.markDoseMissed(id);
      await pumpEventQueue();
      expect(requests.statuses, List.filled(4, pendingUpdate));

      requests.id = 'd-new';
      await repo.addDoseLog(
        DoseLog(
          id: 'd-new',
          prescriptionId: prescriptionId,
          scheduledTime: DateTime(2026, 3, 1, 16),
        ),
      );
      await pumpEventQueue();
      expect(requests.statuses, hasLength(5));
      expect(requests.statuses.last, pendingCreate);
    });

    test('generating asks for one sync, and only when it wrote', () async {
      final db = await AppDatabase.instance.database;
      final prescriptionId = (await seedPrescription(
        db,
        durationDays: 1,
      )).prescriptionId;
      final requests = _Requests('dose_logs');
      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
        requestSync: requests.call,
      );

      final generated = await repo.generateDoseLogsForPrescription(
        prescriptionId,
      );
      requests.id = generated.dataOrNull!.first.id;
      await pumpEventQueue();
      expect(requests.statuses, [pendingCreate]);

      // Everything exists already: nothing written, nothing to push.
      await repo.generateDoseLogsForPrescription(prescriptionId);
      await pumpEventQueue();
      expect(requests.statuses, hasLength(1));
    });

    test('an as-needed prescription generates nothing and asks for no '
        'sync', () async {
      final db = await AppDatabase.instance.database;
      final prescriptionId = (await seedPrescription(
        db,
        scheduleType: 'as_needed',
      )).prescriptionId;
      final requests = _Requests('dose_logs');
      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
        requestSync: requests.call,
      );

      final generated = await repo.generateDoseLogsForPrescription(
        prescriptionId,
      );
      await repo.regenerateDoseLogsForPrescription(prescriptionId);
      await pumpEventQueue();

      expect(generated.dataOrNull, isEmpty);
      expect(await db.query('dose_logs'), isEmpty);
      expect(requests.statuses, isEmpty);
    });

    test(
      'marking overdue doses asks for a sync only when one changed',
      () async {
        final db = await AppDatabase.instance.database;
        final prescriptionId = (await seedPrescription(db)).prescriptionId;
        final id = await seedDoseLog(
          db,
          prescriptionId,
          DateTime(2026, 3, 1, 8),
        );
        final requests = _Requests('dose_logs')..id = id;
        final repo = DoseLogRepositoryImpl(
          localDatasource: DoseLogLocalDatasource(),
          prescriptionLocal: PrescriptionLocalDatasource(),
          requestSync: requests.call,
        );

        await repo.markOverduePendingAsMissed(DateTime(2026, 3, 1, 7));
        await pumpEventQueue();
        expect(requests.statuses, isEmpty);

        await repo.markOverduePendingAsMissed(DateTime(2026, 3, 1, 9));
        await pumpEventQueue();
        expect(requests.statuses, [pendingUpdate]);
      },
    );

    test('a failed status change asks for none', () async {
      final requests = _Requests('dose_logs');
      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
        requestSync: requests.call,
      );

      await repo.markDoseTaken('missing');
      await pumpEventQueue();

      expect(requests.statuses, isEmpty);
    });
  });
}
