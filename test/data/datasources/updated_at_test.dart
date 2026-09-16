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
        startDate: DateTime(2026, 3),
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

  group('a flag change is stamped after the row\'s current stamp', () {
    // The row took a server stamp that is ahead of this device's clock (the
    // sync cycle adopts it). A later local change must still look newer to
    // last-write-wins.
    final ahead = DateTime.now().toUtc().add(const Duration(minutes: 2));

    Future<void> stampAhead(String table, String id) async {
      final db = await AppDatabase.instance.database;
      await db.update(
        table,
        {'updated_at': ahead.toIso8601String()},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    Future<DateTime> stampOf(String table, String id) async {
      final db = await AppDatabase.instance.database;
      final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
      return DateTime.parse(rows.single['updated_at'] as String).toUtc();
    }

    test('prescription deactivate and reactivate', () async {
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).prescriptionId;
      final ds = PrescriptionLocalDatasource();

      await stampAhead('prescriptions', id);
      await ds.deactivate(id);
      final deactivated = await stampOf('prescriptions', id);
      expect(deactivated.isAfter(ahead), isTrue);

      await ds.reactivate(id);
      expect((await stampOf('prescriptions', id)).isAfter(deactivated), isTrue);
    });

    test('medication archive and unarchive', () async {
      final db = await AppDatabase.instance.database;
      final id = (await seedPrescription(db)).medicationId;
      final ds = MedicationLocalDatasource();

      await stampAhead('medications', id);
      await ds.archiveMedication(id);
      final archived = await stampOf('medications', id);
      expect(archived.isAfter(ahead), isTrue);

      await ds.unarchiveMedication(id);
      expect((await stampOf('medications', id)).isAfter(archived), isTrue);
    });
  });
}
