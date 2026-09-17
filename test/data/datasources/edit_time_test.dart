/// Every local write stamps when it was made (`edited_at`), so a merge can
/// tell a person's change from an older one, and from the app's own
/// (1970). A row stored from the server is left to the sync cycle.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/treatment_model.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> row(String table, String id) async =>
      (await (await AppDatabase.instance.database).query(
        table,
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('a pending upsert takes the model stamp; a synced one leaves the '
      'column alone', () async {
    final local = MedicationLocalDatasource();
    final at = DateTime(2026, 3, 5, 10);
    await local.upsert(
      MedicationModel(id: 'm1', name: 'Ibu', quantity: 1, updatedAt: at),
      syncStatus: SyncStatus.pendingUpdate,
    );
    expect((await row('medications', 'm1'))['edited_at'], at.toIso8601String());
    await local.upsert(
      MedicationModel(
        id: 'm1',
        name: 'Ibu',
        quantity: 1,
        updatedAt: DateTime(2026, 3, 5, 11),
      ),
      syncStatus: SyncStatus.synced,
    );
    expect((await row('medications', 'm1'))['edited_at'], at.toIso8601String());
  });

  test('archiving, a treatment edit and deletes stamp now', () async {
    final meds = MedicationLocalDatasource();
    await meds.upsert(
      const MedicationModel(id: 'm1', name: 'Ibu', quantity: 1),
      syncStatus: SyncStatus.synced,
    );
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await meds.archiveMedication('m1');
    final archived = (await row('medications', 'm1'))['edited_at']! as String;
    expect(DateTime.parse(archived).isAfter(before), isTrue);
    expect(archived, (await row('medications', 'm1'))['updated_at']);

    final treatments = TreatmentLocalDatasource();
    await treatments.upsert(
      TreatmentModel(
        id: 't1',
        name: 'Flu',
        startDate: DateTime(2026, 3),
        updatedAt: DateTime(2026, 3, 5, 9),
      ),
      syncStatus: SyncStatus.pendingUpdate,
    );
    expect(
      (await row('treatments', 't1'))['edited_at'],
      DateTime(2026, 3, 5, 9).toIso8601String(),
    );
    await treatments.markDeleted('t1');
    final deleted = (await row('treatments', 't1'))['edited_at']! as String;
    expect(DateTime.parse(deleted).isAfter(before), isTrue);
  });

  test('a dose status change and a prescription pause stamp the same instant '
      'as updated_at', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );
    await DoseLogLocalDatasource().updateStatus(
      doseId,
      'taken',
      takenTime: DateTime(2026, 3, 1, 8, 5),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final dose = await row('dose_logs', doseId);
    expect(dose['edited_at'], dose['updated_at']);

    await PrescriptionLocalDatasource().deactivate(seeded.prescriptionId);
    final p = await row('prescriptions', seeded.prescriptionId);
    expect(p['edited_at'], p['updated_at']);
  });

  test(
    'a person\'s delete of a dose stamps now and is never guarded',
    () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final doseId = await seedDoseLog(
        db,
        seeded.prescriptionId,
        DateTime(2026, 3, 1, 8),
      );
      await db.update('dose_logs', {
        'delete_guard': 'if_pending',
        'edited_at': generatedUpdatedAt.toIso8601String(),
      });
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await DoseLogLocalDatasource().markDeleted(doseId);
      final dose = await row('dose_logs', doseId);
      expect(dose['delete_guard'], isNull);
      expect(
        DateTime.parse(dose['edited_at']! as String).isAfter(before),
        isTrue,
      );
    },
  );

  test('a generated dose carries the automatic 1970 edit time', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await DoseLogLocalDatasource().insertBatchIfAbsent([
      DoseLogModel(
        id: 'g1',
        prescriptionId: seeded.prescriptionId,
        scheduledTime: DateTime(2026, 3, 1, 8),
        updatedAt: generatedUpdatedAt,
      ),
    ], syncStatus: SyncStatus.pendingCreate);
    expect(
      (await row('dose_logs', 'g1'))['edited_at'],
      generatedUpdatedAt.toIso8601String(),
    );
  });
}
