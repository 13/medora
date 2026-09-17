/// A prescription deleted on this device refuses every edit, as treatments
/// and medications do: an edit would bring it back, and its doses with it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/domain/entities/prescription.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  var syncRequests = 0;
  late String id;
  late PrescriptionRepositoryImpl repo;
  setUp(() async {
    syncRequests = 0;
    final db = await AppDatabase.instance.database;
    id = (await seedPrescription(db)).prescriptionId;
    // The seed is stamped with the real clock; start before the test's.
    await db.update('prescriptions', {
      'updated_at': '2026-03-01T00:00:00.000Z',
    });
    repo = PrescriptionRepositoryImpl(
      localDatasource: PrescriptionLocalDatasource(),
      requestSync: () async {
        syncRequests++;
      },
      now: () => DateTime.utc(2026, 3, 5, 8).toLocal(),
    );
  });

  Future<Map<String, Object?>> row() async =>
      (await (await AppDatabase.instance.database).query(
        'prescriptions',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  Future<Prescription> current() async =>
      (await repo.getPrescriptionById(id)).dataOrNull!;

  group('after a delete on this device', () {
    late Map<String, Object?> deleted;
    setUp(() async {
      expect((await repo.deletePrescription(id)).isSuccess, isTrue);
      deleted = await row();
      expect(deleted['sync_status'], SyncStatus.pendingDelete);
      syncRequests = 0;
    });

    Future<void> expectRefused(Future<bool> Function() edit) async {
      expect(await edit(), isFalse);
      expect(await row(), deleted, reason: 'the delete stands');
      expect(syncRequests, 0);
    }

    test('an update is refused', () async {
      final p = await current();
      await expectRefused(
        () async => (await repo.updatePrescription(
          p.copyWith(dosage: '2 tablets'),
        )).isSuccess,
      );
    });

    test('a pause is refused', () async {
      await expectRefused(
        () async => (await repo.deactivatePrescription(id)).isSuccess,
      );
    });

    test('a resume is refused', () async {
      await expectRefused(
        () async => (await repo.reactivatePrescription(id)).isSuccess,
      );
    });
  });

  test('a pause and a resume of a live prescription still work', () async {
    expect((await repo.deactivatePrescription(id)).isSuccess, isTrue);
    expect((await row())['is_active'], 0);
    expect((await repo.reactivatePrescription(id)).isSuccess, isTrue);
    final resumed = await row();
    expect(resumed['is_active'], 1);
    expect(resumed['sync_status'], SyncStatus.pendingUpdate);
    expect(syncRequests, 2);
  });

  test('pausing a prescription that is not there fails', () async {
    expect((await repo.deactivatePrescription('nope')).isSuccess, isFalse);
    expect((await repo.reactivatePrescription('nope')).isSuccess, isFalse);
  });

  test('an update is stamped with the repository clock', () async {
    final p = await current();
    final saved = await repo.updatePrescription(p.copyWith(dosage: '2'));
    expect(saved.dataOrNull!.updatedAt, isNotNull);
    final stored = await row();
    expect(stored['edited_at'], '2026-03-05T08:00:00.000Z');
    expect(stored['dosage'], '2');
  });
}
