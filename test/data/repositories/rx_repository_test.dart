import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/rx_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';

import '../../helpers/failing_medication_repo.dart';
import '../../helpers/test_database.dart';

/// Records stock changes and fails them: the dispensing must be kept
/// whatever the stock does.
class _StockSpy extends FailingMedicationRepo {
  final calls = <(String, int)>[];
  @override
  Future<Result<Medication>> updateQuantity(String id, int delta) async {
    calls.add((id, delta));
    return const Result.failure('not needed');
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 23, 10);
  late _StockSpy stock;
  late RxRepositoryImpl repo;
  var syncs = 0;

  setUp(() {
    syncs = 0;
    stock = _StockSpy();
    repo = RxRepositoryImpl(
      rxLocal: RxLocalDatasource(now: () => now),
      dispensingLocal: RxDispensingLocalDatasource(now: () => now),
      medications: stock,
      requestSync: () async => syncs++,
      now: () => now,
    );
  });

  Rx rx(String id, {String? nre = '0410A1234567890'}) => Rx(
    id: id,
    kind: RxKind.ssn,
    nre: nre,
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [
      RxItem(id: 'i1', medicationId: 'm1', description: 'X', packs: 2),
    ],
  );

  test('saving stores the rx as pending and asks for a sync', () async {
    final saved = await repo.saveRx(rx('r1'));
    expect(saved.isSuccess, isTrue);
    final db = await AppDatabase.instance.database;
    expect(
      (await db.query('rx')).single['sync_status'],
      SyncStatus.pendingCreate,
    );
    await Future<void>.delayed(Duration.zero);
    expect(syncs, 1);
  });

  test('a second rx with the same NRE is refused, naming the first', () async {
    await repo.saveRx(rx('r1'));
    final second = await repo.saveRx(rx('r2'));
    expect(second.isFailure, isTrue);
    second.when(
      success: (_) => fail('saved'),
      failure: (m) => expect(m, '${duplicateNrePrefix}r1'),
    );
  });

  test('editing the same rx keeps its NRE without a duplicate error', () async {
    await repo.saveRx(rx('r1'));
    final again = await repo.saveRx(rx('r1').copyWith(doctor: 'Dr. B'));
    expect(again.isSuccess, isTrue);
    final db = await AppDatabase.instance.database;
    expect(
      (await db.query('rx')).single['sync_status'],
      SyncStatus.pendingUpdate,
    );
  });

  test('an rx without NRE never collides', () async {
    expect((await repo.saveRx(rx('r1', nre: null))).isSuccess, isTrue);
    expect((await repo.saveRx(rx('r2', nre: null))).isSuccess, isTrue);
  });

  test('redeeming records dispensings and adds their units to stock', () async {
    await repo.saveRx(rx('r1'));
    final result = await repo.redeem('r1', [
      RxDispensing(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 23),
        unitsAdded: 20,
      ),
    ]);
    expect(result.isSuccess, isTrue);
    expect(stock.calls, [('m1', 20)]);
    // The spy fails every stock change: the collection is kept, and the
    // caller learns the stock was not updated.
    expect(result.dataOrNull!.stockFailures, 1);
    final back = (await repo.getById('r1')).dataOrNull!;
    expect(back.dispensings.single.packs, 1);
    expect(back.statusAt(now), RxStatus.partial);
  });

  test('a dispensing with no units added leaves the stock alone', () async {
    await repo.saveRx(rx('r1'));
    await repo.redeem('r1', [
      RxDispensing(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 2,
        dispensedOn: DateTime(2026, 9, 23),
      ),
    ]);
    expect(stock.calls, isEmpty);
    expect(
      (await repo.getById('r1')).dataOrNull!.statusAt(now),
      RxStatus.redeemed,
    );
  });

  test(
    'undoing a dispensing removes it; the stock stays as the user left it',
    () async {
      await repo.saveRx(rx('r1'));
      await repo.redeem('r1', [
        RxDispensing(
          id: 'd1',
          rxId: 'r1',
          itemId: 'i1',
          packs: 1,
          dispensedOn: DateTime(2026, 9, 23),
          unitsAdded: 20,
        ),
      ]);
      await repo.undoDispensing('d1');
      expect((await repo.getById('r1')).dataOrNull!.dispensings, isEmpty);
      expect(stock.calls, [('m1', 20)]);
    },
  );
}
