import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/repositories/attachment_repository_impl.dart';
import 'package:medora/data/repositories/rx_repository_impl.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/attachment_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/attachment_import.dart';

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

  group('deleting a prescription', () {
    late Directory attachmentsRoot;
    late AttachmentRepositoryImpl attachments;

    setUp(() async {
      attachmentsRoot = await Directory.systemTemp.createTemp('rx-att');
      attachments = AttachmentRepositoryImpl(
        local: AttachmentLocalDatasource(now: () => now),
        files: AttachmentFiles(rootDirectory: () async => attachmentsRoot),
        now: () => now,
      );
      repo = RxRepositoryImpl(
        rxLocal: RxLocalDatasource(now: () => now),
        dispensingLocal: RxDispensingLocalDatasource(now: () => now),
        medications: stock,
        attachments: attachments,
        requestSync: () async => syncs++,
        now: () => now,
      );
    });
    tearDown(() => attachmentsRoot.delete(recursive: true));

    test('deleteRx tombstones the rx\'s attachments', () async {
      await repo.saveRx(rx('r1'));
      final a1 = (await attachments.add(
        AttachmentOwnerKind.rx,
        'r1',
        Imported(
          kind: AttachmentKind.photo,
          mime: 'image/jpeg',
          bytes: Uint8List.fromList([1, 2, 3]),
          sha256: 'abc',
        ),
      )).dataOrNull!;

      final result = await repo.deleteRx('r1');

      expect(result.isSuccess, isTrue);
      final remaining = await attachments.forOwner(
        AttachmentOwnerKind.rx,
        'r1',
      );
      expect(remaining.dataOrNull, isEmpty);
      // The file is removed too, but that's AttachmentRepositoryImpl's own
      // behaviour (covered in attachment_repository_test.dart); the point
      // here is that deleteRx actually calls through to it.
      final db = await AppDatabase.instance.database;
      final row = (await db.query(
        'attachments',
        where: 'id = ?',
        whereArgs: [a1.id],
      )).single;
      expect(row['deleted_at'], isNotNull);
    });

    test(
      'when attachment deletion fails, the rx stays live and dispensings are not tombstoned',
      () async {
        await repo.saveRx(rx('r1'));
        await repo.redeem('r1', [
          RxDispensing(
            id: 'd1',
            rxId: 'r1',
            itemId: 'i1',
            packs: 1,
            dispensedOn: DateTime(2026, 9, 23),
          ),
        ]);

        // Replace with a failing attachment repo
        repo = RxRepositoryImpl(
          rxLocal: RxLocalDatasource(now: () => now),
          dispensingLocal: RxDispensingLocalDatasource(now: () => now),
          medications: stock,
          attachments: _FailingAttachmentRepo(),
          requestSync: () async => syncs++,
          now: () => now,
        );

        final result = await repo.deleteRx('r1');

        // Deletion should fail
        expect(result.isFailure, isTrue);

        // The rx should still exist
        final rxStillExists = await repo.getById('r1');
        expect(rxStillExists.isSuccess, isTrue);

        // The dispensing should still exist
        expect(rxStillExists.dataOrNull!.dispensings, isNotEmpty);
      },
    );
  });
}

/// Fake attachment repository that always fails deleteForOwner.
class _FailingAttachmentRepo implements AttachmentRepository {
  @override
  Future<Result<List<Attachment>>> forOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async => const Result.success([]);

  @override
  Future<Result<Attachment>> add(
    AttachmentOwnerKind kind,
    String ownerId,
    Imported imported,
  ) async => const Result.failure('not used in this test');

  @override
  Future<Result<void>> delete(String id) async =>
      const Result.failure('not used in this test');

  @override
  Future<Result<void>> deleteForOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async => const Result.failure('attachment cleanup failed');

  @override
  Future<Result<bool>> markUploaded(String id, String remotePath) async =>
      const Result.failure('not used in this test');

  @override
  Future<Result<Map<String, int>>> countsForKind(
    AttachmentOwnerKind kind,
  ) async => const Result.success({});
}
