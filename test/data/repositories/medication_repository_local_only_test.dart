import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('add, read, update quantity and delete work with no remote datasource', () async {
    final repo = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      remoteDatasource: null,
    );

    final added = await repo.addMedication(const Medication(id: 'm1', name: 'Moment', quantity: 10));
    expect(added.isSuccess, isTrue);

    final list = await repo.getMedications();
    expect(list.dataOrNull?.map((m) => m.name), ['Moment']);

    final bumped = await repo.updateQuantity('m1', -3);
    expect(bumped.dataOrNull?.quantity, 7);

    final deleted = await repo.deleteMedication('m1');
    expect(deleted.isSuccess, isTrue);
    expect((await repo.getMedications()).dataOrNull, isEmpty);
  });
}
