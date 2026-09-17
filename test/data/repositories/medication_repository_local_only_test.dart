import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test(
    'add, read, update quantity and delete work with no remote datasource',
    () async {
      final repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
      );

      final added = await repo.addMedication(
        const Medication(id: 'm1', name: 'Moment', quantity: 10),
      );
      expect(added.isSuccess, isTrue);

      final list = await repo.getMedications();
      expect(list.dataOrNull?.map((m) => m.name), ['Moment']);

      final bumped = await repo.updateQuantity('m1', -3);
      expect(bumped.dataOrNull?.quantity, 7);

      final deleted = await repo.deleteMedication('m1');
      expect(deleted.isSuccess, isTrue);
      expect((await repo.getMedications()).dataOrNull, isEmpty);
    },
  );

  test('a stock change keeps every other column, the EAN included', () async {
    // Taking a dose with auto-diminish runs through updateQuantity. The row
    // it writes is pushed whole, with `ean` always sent, so a dropped EAN
    // would also be erased on the server.
    final repo = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
    );
    await repo.addMedication(
      const Medication(
        id: 'm1',
        name: 'Moment',
        quantity: 10,
        barcode: '012345678',
        ean: '8001234567890',
        notes: 'after meals',
      ),
    );

    final bumped = await repo.updateQuantity('m1', -1);
    expect(bumped.dataOrNull?.ean, '8001234567890');

    final stored = (await MedicationLocalDatasource().getMedicationById('m1'))!;
    expect(stored.quantity, 9);
    expect(stored.ean, '8001234567890');
    expect(stored.barcode, '012345678');
    expect(stored.notes, 'after meals');
  });

  group('a deleted medication stays deleted', () {
    Future<Map<String, Object?>> row(String id) async {
      final db = await AppDatabase.instance.database;
      return (await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
    }

    late MedicationRepositoryImpl repo;
    late int requests;

    setUp(() async {
      requests = 0;
      repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
        requestSync: () async => requests++,
      );
      await repo.addMedication(
        const Medication(id: 'm1', name: 'Moment', quantity: 10),
      );
      await repo.deleteMedication('m1');
      await pumpEventQueue();
      requests = 0;
    });

    Future<void> expectStillDeleted() async {
      final stored = await row('m1');
      expect(stored['sync_status'], SyncStatus.pendingDelete);
      expect(stored['deleted_at'], isNotNull);
      expect(stored['quantity'], 10);
      expect(stored['is_archived'], 0);
      expect((await repo.getMedications()).dataOrNull, isEmpty);
      await pumpEventQueue();
      expect(requests, 0);
    }

    test('a stock change fails', () async {
      final result = await repo.updateQuantity('m1', -1);
      expect(result.isSuccess, isFalse);
      await expectStillDeleted();
    });

    test('an edit fails', () async {
      final result = await repo.updateMedication(
        const Medication(id: 'm1', name: 'Moment Act', quantity: 4),
      );
      expect(result.isSuccess, isFalse);
      expect((await row('m1'))['name'], 'Moment');
      await expectStillDeleted();
    });

    test('archiving and unarchiving change nothing', () async {
      await repo.archiveMedication('m1');
      await repo.unarchiveMedication('m1');
      await expectStillDeleted();
    });
  });

  group('a medication the server has not seen stays a create', () {
    test('after a stock change, an edit, archiving and unarchiving', () async {
      final repo = MedicationRepositoryImpl(
        localDatasource: MedicationLocalDatasource(),
      );
      await repo.addMedication(
        const Medication(id: 'm1', name: 'Moment', quantity: 10),
      );
      final db = await AppDatabase.instance.database;
      Future<Object?> status() async => (await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: ['m1'],
      )).single['sync_status'];

      await repo.updateQuantity('m1', -1);
      expect(await status(), SyncStatus.pendingCreate);
      final stored = (await repo.getMedicationById('m1')).dataOrNull!;
      await repo.updateMedication(stored.copyWith(name: 'Moment Act'));
      expect(await status(), SyncStatus.pendingCreate);
      await repo.archiveMedication('m1');
      await repo.unarchiveMedication('m1');
      expect(await status(), SyncStatus.pendingCreate);

      // Without sync, a stock change of a synced row changes the quantity
      // (and its stamp) only: nothing is queued, and a later sign-in
      // uploads the change.
      await db.update('medications', {'sync_status': SyncStatus.synced});
      await repo.updateQuantity('m1', -1);
      expect(await status(), SyncStatus.synced);
      expect((await repo.getMedicationById('m1')).dataOrNull!.quantity, 8);
      expect(await db.query('stock_outbox'), isEmpty);
    });
  });
}
