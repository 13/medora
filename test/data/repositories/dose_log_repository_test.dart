import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';

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

  test('generating never replaces a dose already stored under a slot\'s id, '
      'whatever its time', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, durationDays: 1);
    final slot = DateTime(2026, 3, 1, 8);
    // An older build stored this slot's dose two hours off, and it was
    // taken there.
    final id = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 10),
      id: scheduledDoseId(seeded.prescriptionId, slot),
      status: 'taken',
      takenTime: DateTime(2026, 3, 1, 10, 5),
    );

    final generated = (await makeRepo().generateDoseLogsForPrescription(
      seeded.prescriptionId,
    )).dataOrNull!;

    expect(generated.map((d) => d.id).where((i) => i == id), hasLength(1));
    final row = (await db.query(
      'dose_logs',
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    expect(row['status'], 'taken');
    expect(row['sync_status'], SyncStatus.synced);
    expect(
      DateTime.parse(row['scheduled_time']! as String),
      DateTime(2026, 3, 1, 10),
    );
    // The other two slots of the day were generated.
    expect(await db.query('dose_logs'), hasLength(3));
  });

  test('regenerating keeps a pending dose stored under a slot\'s id at '
      'another time', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, durationDays: 1);
    final slot = DateTime(2026, 3, 1, 16);
    final id = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 18),
      id: scheduledDoseId(seeded.prescriptionId, slot),
    );
    final other = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 19),
    );

    await makeRepo().regenerateDoseLogsForPrescription(seeded.prescriptionId);

    final ids = [for (final r in await db.query('dose_logs')) r['id']];
    expect(ids, contains(id));
    expect(ids, isNot(contains(other)));
    expect(ids, hasLength(3));
  });

  test('a scheduled dose id depends on the prescription and the minute', () {
    expect(
      scheduledDoseId('p1', DateTime(2026, 3, 1, 8, 0, 30)),
      scheduledDoseId('p1', DateTime(2026, 3, 1, 8)),
    );
    expect(
      scheduledDoseId('p1', DateTime(2026, 3, 1, 8)),
      isNot(scheduledDoseId('p2', DateTime(2026, 3, 1, 8))),
    );
    // The ids already on servers were made from this key; it must not move.
    expect(doseSlotKey(DateTime(2026, 3, 1, 8, 5)), '2026-03-01T08:05');
    expect(
      scheduledDoseId('p1', DateTime(2026, 3, 1, 8)),
      '70857337-6964-53ed-9ab1-dce41e155305',
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
