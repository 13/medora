import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
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
    nre: '041A00012345678',
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [
      RxItem(
        id: 'i1',
        description: 'Tachipirina 20 cpr',
        packs: 2,
        nonSubstitutable: true,
        posology: '1x3 bei Bedarf',
      ),
    ],
    createdAt: at,
    updatedAt: at,
  );

  test('an rx round-trips through the local table, items included', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('r1'))!;
    expect(back.nre, '041A00012345678');
    expect(back.issuedOn, DateTime(2026, 9, 20));
    expect(back.validUntil, DateTime(2026, 10, 20));
    expect(back.items.single.nonSubstitutable, isTrue);
    expect(back.items.single.packs, 2);
    expect(back.items.single.posology, '1x3 bei Bedarf');
    expect((await local.getByNre('041A00012345678'))?.id, 'r1');
  });

  test('item posology round-trips through the wire JSON', () {
    final back = RxModel.fromJson(rx.toJson()).toDomain();
    expect(back.items.single.posology, '1x3 bei Bedarf');
    final bare = RxModel.fromJson(
      RxModel.fromDomain(
        back.copyWith(
          items: [const RxItem(id: 'i2', description: 'Aspirina')],
        ),
      ).toJson(),
    );
    expect(bare.items.single.posology, isNull);
    expect(bare.items.single.toJson().containsKey('posology'), isFalse);
  });

  test('a pin round-trips with an NRBE', () async {
    final local = RxLocalDatasource(now: () => at);
    final white = RxModel(
      id: 'r2',
      kind: RxKind.white,
      nre: 'G00001234567',
      pin: '7XQ2K',
      issuedOn: DateTime(2026, 9, 20),
      createdAt: at,
      updatedAt: at,
    );
    await local.upsert(white, syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('r2'))!;
    expect(back.nre, 'G00001234567');
    expect(back.pin, '7XQ2K');
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

  test('a doctor-only pending update does not restamp items '
      '(a fresh List each toJson() must not read as a change)', () async {
    // A real, advancing clock: `RxModel.toJson()` builds a new `items`
    // List every call, so an identity comparison of wire values would
    // see it as "changed" on every write, however small, and keep
    // bumping its edit time. This is only visible from the second
    // pending write on: the first one always fills every column's time
    // from the row's own time (`FieldTimes.stamped`'s empty-map branch),
    // items included.
    var now = at;
    final local = RxLocalDatasource(now: () => now);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    now = at.add(const Duration(minutes: 1));
    await local.upsert(
      rx.copyWith(updatedAt: now),
      syncStatus: SyncStatus.pendingUpdate,
    );
    now = at.add(const Duration(minutes: 2));
    await local.upsert(
      rx.copyWith(doctor: 'Dr. Rossi', updatedAt: now),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final db = await AppDatabase.instance.database;
    final row = (await db.query('rx')).single;
    final times = FieldTimes.decode(row['field_edited_at']);
    expect(
      times.entries['doctor'],
      FieldTime(at.add(const Duration(minutes: 2))),
    );
    // Not moved by either the second or third write: still the first
    // write's edited_at, from the initial fill.
    expect(times.entries['items'], FieldTime(at));
  });

  test('an items change stamps items in field_edited_at', () async {
    var now = at;
    final local = RxLocalDatasource(now: () => now);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    now = at.add(const Duration(minutes: 1));
    final changed = RxModel(
      id: rx.id,
      personId: rx.personId,
      kind: rx.kind,
      nre: rx.nre,
      issuedOn: rx.issuedOn,
      validUntil: rx.validUntil,
      items: const [
        RxItem(
          id: 'i1',
          description: 'Tachipirina 20 cpr',
          packs: 3,
          nonSubstitutable: true,
        ),
      ],
      createdAt: rx.createdAt,
      updatedAt: now,
    );
    await local.upsert(changed, syncStatus: SyncStatus.pendingUpdate);
    final db = await AppDatabase.instance.database;
    final row = (await db.query('rx')).single;
    final times = FieldTimes.decode(row['field_edited_at']);
    expect(times.entries['items'], FieldTime(now));
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
