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
    remoteDatasource: null,
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
}
