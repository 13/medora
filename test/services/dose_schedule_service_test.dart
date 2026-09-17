import 'dart:convert';

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
  final corrections = <Map<String, DateTime>>[];

  @override
  Future<Result<int>> correctDoseTimes(Map<String, DateTime> slotTimes) {
    corrections.add(slotTimes);
    return super.correctDoseTimes(slotTimes);
  }

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

  group('a slot an older build stored hours off (S-1)', () {
    final slot = DateTime(2026, 3, 1, 16);

    /// A day of generated doses, synced as a pull stores them, with the
    /// [slot] dose moved to [at]; returns the prescription and that dose.
    Future<(String, String)> seedShifted(DateTime at) async {
      final db = await AppDatabase.instance.database;
      final p = await seedPrescription(db, startTime: start, durationDays: 1);
      await doses.generateDoseLogsForPrescription(p.prescriptionId);
      await db.update('dose_logs', {
        'sync_status': 'synced',
        'sync_version': 1,
      });
      final id = scheduledDoseId(p.prescriptionId, slot);
      await db.update(
        'dose_logs',
        {'scheduled_time': at.toIso8601String()},
        where: 'id = ?',
        whereArgs: [id],
      );
      return (p.prescriptionId, id);
    }

    Future<Map<String, Object?>> row(String id) async =>
        (await (await AppDatabase.instance.database).query(
          'dose_logs',
          where: 'id = ?',
          whereArgs: [id],
        )).single;

    test('moves back to its time as a change the app made', () async {
      final (_, id) = await seedShifted(DateTime(2026, 3, 1, 18));

      expect(await service.ensureScheduled(), 0);

      expect(doses.corrections, [
        {id: slot},
      ]);
      final moved = await row(id);
      expect(DateTime.parse(moved['scheduled_time']! as String), slot);
      expect(moved['sync_status'], 'pending_update');
      expect(moved['edited_at'], '1970-01-01T00:00:00.000Z');
      expect(
        (jsonDecode(moved['field_edited_at']! as String)
            as Map)['scheduled_time'],
        {'at': '1970-01-01T00:00:00.000Z', 'auto': true},
      );
      expect(await service.ensureScheduled(), 0);
      expect(doses.corrections, hasLength(1));
    });

    test('a dose a person touched stays where it is', () async {
      final (_, id) = await seedShifted(DateTime(2026, 3, 1, 18));
      final db = await AppDatabase.instance.database;
      await db.update(
        'dose_logs',
        {'edited_at': '2026-03-01T09:00:00.000Z'},
        where: 'id = ?',
        whereArgs: [id],
      );

      await service.ensureScheduled();

      final kept = await row(id);
      expect(
        DateTime.parse(kept['scheduled_time']! as String),
        DateTime(2026, 3, 1, 18),
      );
      expect(kept['sync_status'], 'synced');
    });

    test('a slot another dose already sits at is not given a second '
        'one', () async {
      final (p, id) = await seedShifted(DateTime(2026, 3, 1, 18));
      final db = await AppDatabase.instance.database;
      await seedDoseLog(db, p, slot, id: 'older-copy');

      await service.ensureScheduled();

      expect(doses.corrections, isEmpty);
      expect(
        await db.query(
          'dose_logs',
          where: 'scheduled_time = ?',
          whereArgs: [slot.toIso8601String()],
        ),
        hasLength(1),
      );
      // The stray copy is off schedule, so the regeneration drops it (here,
      // without sync, at once).
      expect(
        await db.query('dose_logs', where: 'id = ?', whereArgs: [id]),
        isEmpty,
      );
    });
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

  group('an ended treatment (review I-3)', () {
    Future<void> setTreatmentActive(String id, {required bool active}) async {
      final db = await AppDatabase.instance.database;
      await db.update(
        'treatments',
        {'is_active': active ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    Future<List<Map<String, Object?>>> prescriptionRows() async =>
        (await AppDatabase.instance.database).query('prescriptions');

    test('its prescriptions get no doses on the schedule check, and stay as '
        'they were stored', () async {
      final db = await AppDatabase.instance.database;
      final p = await seedPrescription(db, startTime: start, durationDays: 1);
      await setTreatmentActive(p.treatmentId, active: false);
      final before = await prescriptionRows();

      expect(await service.ensureScheduled(), 0);
      expect(doses.regenerations, 0);
      expect(await db.query('dose_logs'), isEmpty);
      // Ending changes nothing about the prescriptions themselves, so
      // nothing about them is pushed.
      expect(await prescriptionRows(), before);
    });

    test('its prescriptions get no doses when a pull brings them', () async {
      final db = await AppDatabase.instance.database;
      final added = await seedPrescription(db, startTime: start);
      final changed = await seedPrescription(db, startTime: start);
      await setTreatmentActive(added.treatmentId, active: false);
      await setTreatmentActive(changed.treatmentId, active: false);

      final handled = await service.applyPulled(
        PulledPrescriptions(
          added: {added.prescriptionId},
          changed: {changed.prescriptionId},
        ),
      );

      expect(handled, 0);
      expect(await db.query('dose_logs'), isEmpty);
    });

    test('generating its doses directly creates none and keeps what was '
        'recorded', () async {
      final db = await AppDatabase.instance.database;
      final p = await seedPrescription(db, startTime: start, durationDays: 1);
      final taken = await seedDoseLog(
        db,
        p.prescriptionId,
        start,
        status: 'taken',
        takenTime: start,
      );
      await setTreatmentActive(p.treatmentId, active: false);

      final generated = await doses.generateDoseLogsForPrescription(
        p.prescriptionId,
      );
      final regenerated = await doses.regenerateDoseLogsForPrescription(
        p.prescriptionId,
      );

      expect(generated.isSuccess, isTrue);
      expect(regenerated.isSuccess, isTrue);
      final rows = await db.query('dose_logs');
      expect(rows.map((r) => r['id']), [taken]);
      expect(rows.single['status'], 'taken');
    });

    test('made active again, it is generated again', () async {
      final db = await AppDatabase.instance.database;
      final p = await seedPrescription(db, startTime: start, durationDays: 1);
      await setTreatmentActive(p.treatmentId, active: false);
      expect(await service.ensureScheduled(), 0);

      await setTreatmentActive(p.treatmentId, active: true);

      expect(await service.ensureScheduled(), 1);
      expect(await db.query('dose_logs'), hasLength(3));
    });
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
