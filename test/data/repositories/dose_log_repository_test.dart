import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  DoseLogRepositoryImpl makeRepo() => DoseLogRepositoryImpl(
    localDatasource: DoseLogLocalDatasource(),
    prescriptionLocal: PrescriptionLocalDatasource(),
  );

  test(
    'markDoseTaken then markDosePending return real rows and clear taken_time',
    () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db, medicationName: 'Brufen');
      final id = await seedDoseLog(
        db,
        seeded.prescriptionId,
        DateTime(2026, 3, 1, 8),
      );
      final repo = makeRepo();

      final taken = (await repo.markDoseTaken(id)).dataOrNull!;
      expect(taken.id, id);
      expect(taken.prescriptionId, seeded.prescriptionId);
      expect(taken.medicationName, 'Brufen');
      expect(taken.scheduledTime, DateTime(2026, 3, 1, 8));
      expect(taken.status, DoseStatus.taken);
      expect(taken.takenTime, isNotNull);

      final pending = (await repo.markDosePending(id)).dataOrNull!;
      expect(pending.status, DoseStatus.pending);
      expect(pending.takenTime, isNull);
      expect(pending.prescriptionId, seeded.prescriptionId);
    },
  );

  test('markDoseSkipped / markDoseMissed return the stored row', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final id = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );
    final repo = makeRepo();

    expect(
      (await repo.markDoseSkipped(id)).dataOrNull!.status,
      DoseStatus.skipped,
    );
    expect(
      (await repo.markDoseMissed(id)).dataOrNull!.status,
      DoseStatus.missed,
    );
  });

  test('marking an unknown id fails', () async {
    final result = await makeRepo().markDoseTaken('missing');
    expect(result.isFailure, isTrue);
  });

  test('a deleted dose can be neither deleted again nor changed', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final id = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
      status: 'taken',
    );
    var requests = 0;
    final repo = DoseLogRepositoryImpl(
      localDatasource: DoseLogLocalDatasource(),
      prescriptionLocal: PrescriptionLocalDatasource(),
      requestSync: () async => requests++,
    );
    expect((await repo.deleteDoseLog(id)).isSuccess, isTrue);
    await pumpEventQueue();
    final tombstone = (await db.query(
      'dose_logs',
      where: 'id = ?',
      whereArgs: [id],
    )).single;

    expect((await repo.deleteDoseLog(id)).isFailure, isTrue);
    expect((await repo.markDosePending(id)).isFailure, isTrue);
    expect((await repo.markDoseTaken(id)).isFailure, isTrue);
    expect((await repo.getDoseLogById(id)).isFailure, isTrue);
    await pumpEventQueue();

    expect(requests, 1);
    final stored = (await db.query(
      'dose_logs',
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    expect(stored, tombstone);
    expect(stored['sync_status'], SyncStatus.pendingDelete);
  });

  test('getDoseLogsByTreatment returns the treatment\'s doses as entities, '
      'and reads nothing it may not push', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, medicationName: 'Brufen');
    final id = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
      status: 'taken',
    );
    final other = await seedPrescription(db);
    await seedDoseLog(db, other.prescriptionId, DateTime(2026, 3, 1, 8));
    final before = await db.query('dose_logs', orderBy: 'id');

    final doses = (await makeRepo().getDoseLogsByTreatment(
      seeded.treatmentId,
    )).dataOrNull!;

    expect(doses.map((d) => d.id), [id]);
    expect(doses.single.status, DoseStatus.taken);
    expect(doses.single.medicationName, 'Brufen');
    // A read: no row changes, nothing is marked for sync.
    expect(await db.query('dose_logs', orderBy: 'id'), before);
  });
}
