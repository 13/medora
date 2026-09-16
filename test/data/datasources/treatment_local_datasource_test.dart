import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('upsert then read keeps the sick-leave columns', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(
        id: 't1',
        name: 'Stirnhöhlenentzündung',
        startDate: DateTime(2026, 3, 2),
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveTo: DateTime(2026, 3, 9),
        sickLeaveRef: '1234567890',
        doctor: 'Dr. Rossi, Bozen',
      ),
      syncStatus: SyncStatus.pendingCreate,
    );

    final stored = await ds.getTreatmentById('t1');
    expect(stored!.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(stored.sickLeaveTo, DateTime(2026, 3, 9));
    expect(stored.sickLeaveRef, '1234567890');
    expect(stored.doctor, 'Dr. Rossi, Bozen');

    final db = await AppDatabase.instance.database;
    final row = (await db.query(
      'treatments',
      where: 'id = ?',
      whereArgs: ['t1'],
    )).single;
    expect(row['sick_leave_from'], '2026-03-03');
    expect(row['sick_leave_to'], '2026-03-09');
    expect(row['sick_leave_ref'], '1234567890');
    expect(row['doctor'], 'Dr. Rossi, Bozen');
  });

  test('a treatment with no sick leave stores nulls', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(
        id: 't2',
        name: 'Vitamin D',
        startDate: DateTime(2026, 3, 2),
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    final stored = await ds.getTreatmentById('t2');
    expect(stored!.sickLeaveFrom, isNull);
    expect(stored.sickLeaveTo, isNull);
    expect(stored.sickLeaveRef, isNull);
    expect(stored.doctor, isNull);
  });

  test('an update clears sick leave that was removed', () async {
    final ds = TreatmentLocalDatasource();
    await ds.upsert(
      TreatmentModel(
        id: 't3',
        name: 'Influenza',
        startDate: DateTime(2026, 3, 2),
        sickLeaveFrom: DateTime(2026, 3, 3),
        sickLeaveRef: 'X1',
        doctor: 'Dr. Bauer',
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    await ds.upsert(
      TreatmentModel(
        id: 't3',
        name: 'Influenza',
        startDate: DateTime(2026, 3, 2),
      ),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final stored = await ds.getTreatmentById('t3');
    expect(stored!.sickLeaveFrom, isNull);
    expect(stored.sickLeaveRef, isNull);
    expect(stored.doctor, isNull);
  });
}
