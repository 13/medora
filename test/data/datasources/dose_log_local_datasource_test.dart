import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test(
    'updateStatus with clearTakenTime nulls taken_time and bumps updated_at',
    () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      final taken = DateTime(2026, 3, 1, 8, 5);
      final id = await seedDoseLog(
        db,
        seeded.prescriptionId,
        DateTime(2026, 3, 1, 8),
        status: 'taken',
        takenTime: taken,
      );
      final ds = DoseLogLocalDatasource();

      final before = (await ds.getDoseLogById(id))!;
      expect(before.status, DoseStatus.taken);
      expect(before.takenTime, taken);

      await ds.updateStatus(
        id,
        'pending',
        clearTakenTime: true,
        syncStatus: SyncStatus.pendingUpdate,
      );

      final after = (await ds.getDoseLogById(id))!;
      expect(after.status, DoseStatus.pending);
      expect(after.takenTime, isNull);
      expect(after.updatedAt, isNotNull);
      expect(after.updatedAt!.isAfter(before.updatedAt!), isTrue);
    },
  );

  test(
    'updateStatus taken writes taken_time and keeps join fields readable',
    () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db, medicationName: 'Moment');
      final id = await seedDoseLog(
        db,
        seeded.prescriptionId,
        DateTime(2026, 3, 1, 8),
      );
      final ds = DoseLogLocalDatasource();

      final at = DateTime(2026, 3, 1, 8, 10);
      await ds.updateStatus(
        id,
        'taken',
        takenTime: at,
        syncStatus: SyncStatus.pendingUpdate,
      );

      final row = (await ds.getDoseLogById(id))!;
      expect(row.status, DoseStatus.taken);
      expect(row.takenTime, at);
      expect(row.medicationName, 'Moment');
      expect(row.prescriptionId, seeded.prescriptionId);
    },
  );

  test('getDoseLogById returns null for unknown id', () async {
    expect(await DoseLogLocalDatasource().getDoseLogById('nope'), isNull);
  });

  group('a pending dose of an as-needed prescription', () {
    // Nothing here creates one any more, but an older app build that reads
    // 'as_needed' as a fixed interval generates them and syncs them over,
    // and a prescription switched to as-needed on another device leaves its
    // old pending doses there. None of them is a dose anyone is due to take.
    final at = DateTime(2026, 3, 1, 8);

    Future<({String pending, String taken})> seed() async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      return (
        pending: await seedDoseLog(db, s.prescriptionId, at),
        taken: await seedDoseLog(
          db,
          s.prescriptionId,
          at.add(const Duration(hours: 1)),
          status: 'taken',
          takenTime: at.add(const Duration(hours: 1)),
        ),
      );
    }

    test('is not listed for its day, while a taken one is', () async {
      final ids = await seed();
      final day = await DoseLogLocalDatasource().getDoseLogsByDateRange(
        DateTime(2026, 3),
        DateTime(2026, 3, 2),
      );
      expect(day.map((d) => d.id), [ids.taken]);
    });

    test('is not listed for today', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db, scheduleType: 'as_needed');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      await seedDoseLog(db, s.prescriptionId, midnight);
      final taken = await seedDoseLog(
        db,
        s.prescriptionId,
        midnight,
        status: 'taken',
        takenTime: midnight,
      );
      final today = await DoseLogLocalDatasource().getTodaysDoseLogs();
      expect(today.map((d) => d.id), [taken]);
    });

    test('is never offered for a reminder', () async {
      await seed();
      final pending = await DoseLogLocalDatasource().getPendingBetween(
        DateTime(2026, 3),
        DateTime(2026, 3, 2),
      );
      expect(pending, isEmpty);
    });

    test('is never marked missed', () async {
      final ids = await seed();
      final changed = await DoseLogLocalDatasource().markOverduePendingAsMissed(
        DateTime(2026, 3, 2),
      );
      expect(changed.changed, 0);
      final row = (await DoseLogLocalDatasource().getDoseLogById(ids.pending))!;
      expect(row.status, DoseStatus.pending);
    });
  });

  test('a pending dose of a scheduled prescription is still listed, '
      'reminded and marked missed', () async {
    // The control for the group above.
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final id = await seedDoseLog(db, s.prescriptionId, DateTime(2026, 3, 1, 8));
    final ds = DoseLogLocalDatasource();
    expect(
      (await ds.getDoseLogsByDateRange(
        DateTime(2026, 3),
        DateTime(2026, 3, 2),
      )).map((d) => d.id),
      [id],
    );
    expect(
      (await ds.getPendingBetween(
        DateTime(2026, 3),
        DateTime(2026, 3, 2),
      )).map((d) => d.id),
      [id],
    );
    expect(
      (await ds.markOverduePendingAsMissed(DateTime(2026, 3, 2))).changed,
      1,
    );
  });

  test('a deleted dose is neither found, changed nor deleted again', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final id = await seedDoseLog(
      db,
      s.prescriptionId,
      DateTime(2026, 3, 1, 8),
      status: 'taken',
    );
    final ds = DoseLogLocalDatasource();
    await ds.markDeleted(id);
    Future<Map<String, Object?>> row() async =>
        (await db.query('dose_logs', where: 'id = ?', whereArgs: [id])).single;
    final tombstone = await row();

    await Future<void>.delayed(const Duration(milliseconds: 2));
    await ds.updateStatus(id, 'pending', syncStatus: SyncStatus.pendingUpdate);
    await ds.markDeleted(id);

    expect(await ds.getDoseLogById(id), isNull);
    expect(await row(), tombstone);
  });

  group('getDoseLogsByTreatment', () {
    test('returns every dose of every prescription under the treatment, '
        'oldest first, with the join fields', () async {
      final db = await AppDatabase.instance.database;
      final a = await seedPrescription(db, medicationName: 'Brufen');
      // A second prescription of the same treatment, logged as needed.
      await db.insert('prescriptions', {
        'id': 'p-as-needed',
        'treatment_id': a.treatmentId,
        'medication_id': a.medicationId,
        'dosage': '1 tablet',
        'interval_hours': 8,
        'duration_days': 0,
        'start_time': DateTime(2026, 3, 1, 8).toIso8601String(),
        'is_active': 1,
        'auto_diminish': 0,
        'schedule_type': 'as_needed',
        'created_at': '2026-03-01T08:00:00.000',
        'updated_at': '2026-03-01T08:00:00.000',
        'sync_status': 'synced',
      });
      await seedDoseLog(
        db,
        a.prescriptionId,
        DateTime(2026, 3, 1, 16),
        status: 'skipped',
      );
      await seedDoseLog(
        db,
        'p-as-needed',
        DateTime(2026, 3, 1, 12),
        status: 'taken',
      );
      await seedDoseLog(
        db,
        a.prescriptionId,
        DateTime(2026, 3, 1, 8),
        status: 'taken',
      );
      // A second, unrelated treatment must not leak in.
      final b = await seedPrescription(db, medicationName: 'Moment');
      await seedDoseLog(
        db,
        b.prescriptionId,
        DateTime(2026, 3, 1, 9),
        status: 'taken',
      );

      final doses = await DoseLogLocalDatasource().getDoseLogsByTreatment(
        a.treatmentId,
      );

      expect(doses.map((d) => d.scheduledTime), [
        DateTime(2026, 3, 1, 8),
        DateTime(2026, 3, 1, 12),
        DateTime(2026, 3, 1, 16),
      ]);
      expect(doses.map((d) => d.prescriptionId), [
        a.prescriptionId,
        'p-as-needed',
        a.prescriptionId,
      ]);
      expect(doses.map((d) => d.status), [
        DoseStatus.taken,
        DoseStatus.taken,
        DoseStatus.skipped,
      ]);
      expect(doses.first.medicationName, 'Brufen');
      expect(doses.map((d) => d.asNeeded), [false, true, false]);
    });

    test('leaves out a deleted dose', () async {
      final db = await AppDatabase.instance.database;
      final s = await seedPrescription(db);
      final kept = await seedDoseLog(
        db,
        s.prescriptionId,
        DateTime(2026, 3, 1, 8),
        status: 'taken',
      );
      final deleted = await seedDoseLog(
        db,
        s.prescriptionId,
        DateTime(2026, 3, 1, 12),
        status: 'taken',
      );
      final ds = DoseLogLocalDatasource();
      await ds.markDeleted(deleted);

      final doses = await ds.getDoseLogsByTreatment(s.treatmentId);
      expect(doses.map((d) => d.id), [kept]);
    });

    test('is empty for a treatment with no doses', () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      expect(
        await DoseLogLocalDatasource().getDoseLogsByTreatment(
          seeded.treatmentId,
        ),
        isEmpty,
      );
    });
  });
}
