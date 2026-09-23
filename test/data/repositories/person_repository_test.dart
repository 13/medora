import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/person_repository_impl.dart';
import 'package:medora/domain/entities/person.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 23, 10);
  late PersonRepositoryImpl repo;
  var syncs = 0;

  setUp(() {
    syncs = 0;
    repo = PersonRepositoryImpl(
      local: PersonLocalDatasource(now: () => now),
      requestSync: () async => syncs++,
      now: () => now,
    );
  });

  Person person(String id, {String name = 'Alice'}) =>
      Person(id: id, name: name);

  test(
    'saving a new person stores it as pending and asks for a sync',
    () async {
      final saved = await repo.savePerson(person('p1'));
      expect(saved.isSuccess, isTrue);
      final db = await AppDatabase.instance.database;
      expect(
        (await db.query('persons')).single['sync_status'],
        SyncStatus.pendingCreate,
      );
      await Future<void>.delayed(Duration.zero);
      expect(syncs, 1);
    },
  );

  test('saving an existing person marks it pending_update', () async {
    await repo.savePerson(person('p1'));
    final again = await repo.savePerson(person('p1', name: 'Alice B.'));
    expect(again.isSuccess, isTrue);
    final db = await AppDatabase.instance.database;
    expect(
      (await db.query('persons')).single['sync_status'],
      SyncStatus.pendingUpdate,
    );
  });

  test('deleting a person hides it from getPersons', () async {
    await repo.savePerson(person('p1'));
    expect((await repo.deletePerson('p1')).isSuccess, isTrue);
    final remaining = (await repo.getPersons()).dataOrNull!;
    expect(remaining, isEmpty);
  });
}
