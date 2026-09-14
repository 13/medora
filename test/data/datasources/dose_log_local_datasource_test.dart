import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('updateStatus with clearTakenTime nulls taken_time and bumps updated_at', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final taken = DateTime(2026, 3, 1, 8, 5);
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8),
        status: 'taken', takenTime: taken);
    final ds = DoseLogLocalDatasource();

    final before = (await ds.getDoseLogById(id))!;
    expect(before.status, DoseStatus.taken);
    expect(before.takenTime, taken);

    await ds.updateStatus(id, 'pending', clearTakenTime: true, syncStatus: SyncStatus.pendingUpdate);

    final after = (await ds.getDoseLogById(id))!;
    expect(after.status, DoseStatus.pending);
    expect(after.takenTime, isNull);
    expect(after.updatedAt, isNotNull);
    expect(after.updatedAt!.isAfter(before.updatedAt!), isTrue);
  });

  test('updateStatus taken writes taken_time and keeps join fields readable', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, medicationName: 'Moment');
    final id = await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final ds = DoseLogLocalDatasource();

    final at = DateTime(2026, 3, 1, 8, 10);
    await ds.updateStatus(id, 'taken', takenTime: at, syncStatus: SyncStatus.pendingUpdate);

    final row = (await ds.getDoseLogById(id))!;
    expect(row.status, DoseStatus.taken);
    expect(row.takenTime, at);
    expect(row.medicationName, 'Moment');
    expect(row.prescriptionId, seeded.prescriptionId);
  });

  test('getDoseLogById returns null for unknown id', () async {
    expect(await DoseLogLocalDatasource().getDoseLogById('nope'), isNull);
  });
}
