import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
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
}
