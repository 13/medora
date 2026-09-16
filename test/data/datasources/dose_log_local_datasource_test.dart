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
      expect(changed, 0);
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
    expect(await ds.markOverduePendingAsMissed(DateTime(2026, 3, 2)), 1);
  });
}
