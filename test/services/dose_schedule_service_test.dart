import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/services/dose_schedule_service.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

/// Counts the regenerations the service asks for.
class _CountingDoses extends DoseLogRepositoryImpl {
  _CountingDoses()
    : super(
        localDatasource: DoseLogLocalDatasource(),
        prescriptionLocal: PrescriptionLocalDatasource(),
      );

  int regenerations = 0;
  int generations = 0;

  @override
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
    String prescriptionId,
  ) {
    regenerations++;
    return super.regenerateDoseLogsForPrescription(prescriptionId);
  }

  @override
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
    String prescriptionId,
  ) {
    generations++;
    return super.generateDoseLogsForPrescription(prescriptionId);
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final start = DateTime(2026, 3, 1, 8);
  late _CountingDoses doses;
  late DoseScheduleService service;

  setUp(() {
    doses = _CountingDoses();
    service = DoseScheduleService(
      prescriptions: PrescriptionRepositoryImpl(
        localDatasource: PrescriptionLocalDatasource(),
      ),
      doses: doses,
      now: () => DateTime(2026, 3, 1, 12),
    );
  });

  test('a complete schedule is left alone', () async {
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db, startTime: start, durationDays: 1);
    await doses.generateDoseLogsForPrescription(p.prescriptionId);

    expect(await service.ensureScheduled(), 0);
    expect(doses.regenerations, 0);
  });

  test('a missing time is generated', () async {
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db, startTime: start, durationDays: 1);
    await doses.generateDoseLogsForPrescription(p.prescriptionId);
    await db.delete(
      'dose_logs',
      where: 'scheduled_time LIKE ?',
      whereArgs: ['%T16%'],
    );

    expect(await service.ensureScheduled(), 1);
    expect(await db.query('dose_logs'), hasLength(3));
  });

  test('an ended prescription is left alone', () async {
    final db = await AppDatabase.instance.database;
    await seedPrescription(
      db,
      startTime: DateTime(2026, 2, 1, 8),
      durationDays: 1,
    );

    expect(await service.ensureScheduled(), 0);
    expect(await db.query('dose_logs'), isEmpty);
  });

  test('a slot stored hours off under its own id is not regenerated', () async {
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db, startTime: start, durationDays: 1);
    await doses.generateDoseLogsForPrescription(p.prescriptionId);
    final slot = DateTime(2026, 3, 1, 16);
    await db.update(
      'dose_logs',
      {'scheduled_time': DateTime(2026, 3, 1, 18).toIso8601String()},
      where: 'id = ?',
      whereArgs: [scheduledDoseId(p.prescriptionId, slot)],
    );

    expect(await service.ensureScheduled(), 0);
    expect(await db.query('dose_logs'), hasLength(3));
  });

  test('a pulled prescription that is paused gets no doses', () async {
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db, startTime: start, durationDays: 1);
    await db.update('prescriptions', {'is_active': 0});

    final handled = await service.applyPulled(
      PulledPrescriptions(added: {p.prescriptionId}),
    );

    expect(handled, 0);
    expect(await db.query('dose_logs'), isEmpty);
  });

  test('a new pulled prescription is generated, a changed one '
      'regenerated', () async {
    final db = await AppDatabase.instance.database;
    final added = await seedPrescription(db, startTime: start);
    final changed = await seedPrescription(db, startTime: start);

    final handled = await service.applyPulled(
      PulledPrescriptions(
        added: {added.prescriptionId},
        changed: {changed.prescriptionId},
      ),
    );

    expect(handled, 2);
    expect(doses.generations, 2); // the regeneration generates too
    expect(doses.regenerations, 1);
  });

  test('calls made while a check runs share it', () async {
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db, startTime: start, durationDays: 1);

    final results = await Future.wait([
      service.ensureScheduled(),
      service.ensureScheduled(),
    ]);

    expect(results, [1, 1]);
    expect(doses.regenerations, 1);
    expect(
      await db.query(
        'dose_logs',
        where: 'prescription_id = ?',
        whereArgs: [p.prescriptionId],
      ),
      hasLength(3),
    );
  });
}
