import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/dose_maintenance_service.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 3, 1, 12);

  test(
    'marks pending doses older than the grace period as missed, leaves the rest',
    () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final old = await seedDoseLog(
        db,
        s.prescriptionId,
        now.subtract(const Duration(hours: 3)),
      );
      final recent = await seedDoseLog(
        db,
        s.prescriptionId,
        now.subtract(const Duration(minutes: 30)),
      );
      final future = await seedDoseLog(
        db,
        s.prescriptionId,
        now.add(const Duration(hours: 1)),
      );
      final taken = await seedDoseLog(
        db,
        s.prescriptionId,
        now.subtract(const Duration(hours: 5)),
        status: 'taken',
      );

      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
      );
      final service = DoseMaintenanceService(doses: repo, now: () => now);
      final changed = await service.markOverdueAsMissed(
        grace: const Duration(minutes: 120),
      );

      expect(changed, 1);
      final ds = DoseLogLocalDatasource();
      expect((await ds.getDoseLogById(old))!.status, DoseStatus.missed);
      expect((await ds.getDoseLogById(recent))!.status, DoseStatus.pending);
      expect((await ds.getDoseLogById(future))!.status, DoseStatus.pending);
      expect((await ds.getDoseLogById(taken))!.status, DoseStatus.taken);
      // Marked rows are flagged for sync and stamped.
      final row = (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [old],
      )).first;
      expect(row['sync_status'], SyncStatus.pendingUpdate);
      expect(row['updated_at'], isNotNull);
    },
  );

  test(
    'does not mark overdue doses of an inactive prescription as missed',
    () async {
      final db = await AppDatabase.instance.database;
      final s1 = await seedPrescription(db);
      final s2 = await seedPrescription(db);
      await db.update(
        'prescriptions',
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: [s2.prescriptionId],
      );
      final active = await seedDoseLog(
        db,
        s1.prescriptionId,
        now.subtract(const Duration(hours: 3)),
      );
      final inactive = await seedDoseLog(
        db,
        s2.prescriptionId,
        now.subtract(const Duration(hours: 3)),
      );

      final repo = DoseLogRepositoryImpl(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
      );
      final service = DoseMaintenanceService(doses: repo, now: () => now);
      final changed = await service.markOverdueAsMissed(
        grace: const Duration(minutes: 120),
      );

      expect(changed, 1);
      final ds = DoseLogLocalDatasource();
      expect((await ds.getDoseLogById(active))!.status, DoseStatus.missed);
      expect((await ds.getDoseLogById(inactive))!.status, DoseStatus.pending);
    },
  );
}
