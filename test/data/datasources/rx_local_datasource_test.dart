import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/person_model.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';
import 'package:medora/data/models/rx_model.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final at = DateTime(2026, 9, 23, 9);
  final rx = RxModel(
    id: 'r1',
    personId: 'p1',
    kind: RxKind.ssn,
    nre: '0410A1234567890',
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [
      RxItem(
        id: 'i1',
        description: 'Tachipirina 20 cpr',
        packs: 2,
        nonSubstitutable: true,
      ),
    ],
    createdAt: at,
    updatedAt: at,
  );

  test('an rx round-trips through the local table, items included', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('r1'))!;
    expect(back.nre, '0410A1234567890');
    expect(back.issuedOn, DateTime(2026, 9, 20));
    expect(back.validUntil, DateTime(2026, 10, 20));
    expect(back.items.single.nonSubstitutable, isTrue);
    expect(back.items.single.packs, 2);
    expect((await local.getByNre('0410A1234567890'))?.id, 'r1');
  });

  test('the wire copy of a stored row equals the model wire copy', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    final db = await AppDatabase.instance.database;
    final row = (await db.query(
      'rx',
      where: 'id = ?',
      whereArgs: ['r1'],
    )).single;
    expect(RxLocalDatasource.wireOf(row), rx.toJson());
  });

  test('a pending write stamps edited_at and field times', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    await local.upsert(
      rx.copyWith(
        doctor: 'Dr. Rossi',
        updatedAt: at.add(const Duration(minutes: 1)),
      ),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final db = await AppDatabase.instance.database;
    final row = (await db.query('rx')).single;
    expect(row['edited_at'], isNotNull);
    expect(row['field_edited_at'] as String?, contains('doctor'));
  });

  test('markDeleted leaves a pending tombstone that getAll hides', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.synced);
    await local.markDeleted('r1');
    expect(await local.getAll(), isEmpty);
    expect((await local.getById('r1'))!.deletedAt, isNotNull);
  });

  test('deleting an rx row cascades to its dispensings', () async {
    final local = RxLocalDatasource(now: () => at);
    final disp = RxDispensingLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.synced);
    await disp.upsert(
      RxDispensingModel(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 22),
        unitsAdded: 20,
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    expect((await disp.getForRx('r1')).single.unitsAdded, 20);
    await local.hardDelete('r1');
    expect(await disp.getForRx('r1'), isEmpty);
  });

  test('a person is found by tax code', () async {
    final persons = PersonLocalDatasource(now: () => at);
    await persons.upsert(
      const PersonModel(
        id: 'p1',
        name: 'Ben',
        taxCode: 'RSSMRA85T10A562S',
        exemptions: ['E01'],
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    final p = (await persons.getByTaxCode('RSSMRA85T10A562S'))!;
    expect(p.exemptions, ['E01']);
  });
}
