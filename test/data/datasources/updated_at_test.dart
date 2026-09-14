import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final remoteStamp = DateTime.utc(2025, 12, 24, 10, 30);

  test(
    'medication upsert preserves an explicit updatedAt (remote pull)',
    () async {
      final ds = MedicationLocalDatasource();
      await ds.upsert(
        MedicationModel(
          id: 'm1',
          name: 'Aspirin',
          quantity: 1,
          updatedAt: remoteStamp,
        ),
        syncStatus: SyncStatus.synced,
      );
      expect((await ds.getMedicationById('m1'))!.updatedAt, remoteStamp);
    },
  );

  test('treatment upsert preserves an explicit updatedAt', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(
        id: 't1',
        name: 'Flu',
        startDate: DateTime(2026, 3, 1),
        updatedAt: remoteStamp,
      ),
      syncStatus: SyncStatus.synced,
    );
    expect((await ds.getTreatmentById('t1'))!.updatedAt, remoteStamp);
  });

  test('prescription upsert preserves an explicit updatedAt', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final ds = PrescriptionLocalDatasource();
    final existing = (await ds.getPrescriptionById(seeded.prescriptionId))!;
    await ds.upsert(
      PrescriptionModel(
        id: existing.id,
        treatmentId: existing.treatmentId,
        medicationId: existing.medicationId,
        dosage: existing.dosage,
        startTime: existing.startTime,
        updatedAt: remoteStamp,
      ),
      syncStatus: SyncStatus.synced,
    );
    expect((await ds.getPrescriptionById(existing.id))!.updatedAt, remoteStamp);
  });

  test('repository add/update stamps updatedAt with now', () async {
    final repo = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      remoteDatasource: null,
    );
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await repo.addMedication(
      const Medication(id: 'm2', name: 'Moment', quantity: 3),
    );
    final added = (await repo.getMedicationById('m2')).dataOrNull!;
    expect(added.updatedAt, isNotNull);
    expect(added.updatedAt!.isAfter(before), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.updateQuantity('m2', -1);
    final bumped = (await repo.getMedicationById('m2')).dataOrNull!;
    expect(bumped.updatedAt!.isAfter(added.updatedAt!), isTrue);
  });
}
