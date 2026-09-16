import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  late TreatmentLocalDatasource local;

  setUp(() => local = TreatmentLocalDatasource());

  final episode = TreatmentModel(
    id: 't1',
    name: 'Stirnhöhlenentzündung',
    patientTags: const ['Ben'],
    symptomTags: const ['Kopfschmerzen'],
    startDate: DateTime(2026, 3, 2),
    notes: 'ging langsam weg',
    sickLeaveFrom: DateTime(2026, 3, 3),
    sickLeaveTo: DateTime(2026, 3, 9),
    sickLeaveRef: '1234567890',
    doctor: 'Dr. Rossi, Bozen',
    createdAt: DateTime(2026, 3, 2, 8),
    updatedAt: DateTime(2026, 3, 2, 8),
  );

  Future<String?> syncStatus(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'treatments',
      columns: ['sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.single['sync_status'] as String?;
  }

  group('local only', () {
    late TreatmentRepositoryImpl repo;

    setUp(() {
      repo = TreatmentRepositoryImpl(
        localDatasource: local,
        // local-only: no sync to ask for
      );
    });

    test('endTreatment keeps every field it does not change', () async {
      await local.upsert(episode, syncStatus: SyncStatus.synced);

      final result = await repo.endTreatment('t1');
      expect(result.isSuccess, isTrue);

      final stored = (await local.getTreatmentById('t1'))!;
      expect(stored.isActive, isFalse);
      expect(stored.endDate, isNotNull);
      // The fields endTreatment must not silently drop:
      expect(stored.sickLeaveFrom, DateTime(2026, 3, 3));
      expect(stored.sickLeaveTo, DateTime(2026, 3, 9));
      expect(stored.sickLeaveRef, '1234567890');
      expect(stored.doctor, 'Dr. Rossi, Bozen');
      expect(stored.notes, 'ging langsam weg');
      expect(stored.patientTags, ['Ben']);
      expect(stored.symptomTags, ['Kopfschmerzen']);
      expect(stored.createdAt, DateTime(2026, 3, 2, 8));
      expect(stored.updatedAt!.isAfter(DateTime(2026, 3, 2, 8)), isTrue);

      // The returned entity carries them too.
      final ended = result.dataOrNull!;
      expect(ended.isActive, isFalse);
      expect(ended.sickLeaveRef, '1234567890');
      expect(ended.doctor, 'Dr. Rossi, Bozen');
    });

    test('endTreatment leaves the row pending for the next sync', () async {
      await local.upsert(episode, syncStatus: SyncStatus.synced);
      await repo.endTreatment('t1');
      expect(await syncStatus('t1'), SyncStatus.pendingUpdate);
    });

    test('endTreatment on a row deleted on this device fails and keeps the '
        'delete pending', () async {
      await local.upsert(episode, syncStatus: SyncStatus.synced);
      await local.markDeleted('t1');

      final result = await repo.endTreatment('t1');
      expect(result.isFailure, isTrue);

      expect(await syncStatus('t1'), SyncStatus.pendingDelete);
      final stored = (await local.getTreatmentById('t1'))!;
      expect(stored.deletedAt, isNotNull);
      expect(stored.isActive, isTrue);
    });

    test('endTreatment on a missing id fails instead of writing', () async {
      final result = await repo.endTreatment('nope');
      expect(result.isFailure, isTrue);
      expect(await local.getTreatments(), isEmpty);
    });
  });

  group('requesting a sync', () {
    late List<String?> statusAtRequest;
    late TreatmentRepositoryImpl repo;
    Object? failWith;

    setUp(() {
      statusAtRequest = [];
      failWith = null;
      repo = TreatmentRepositoryImpl(
        localDatasource: local,
        requestSync: () async {
          // The sync cycle pushes whatever is pending when it runs, so the
          // local write must be complete before the request.
          final db = await AppDatabase.instance.database;
          final rows = await db.query(
            'treatments',
            columns: ['sync_status'],
            where: 'id = ?',
            whereArgs: ['t1'],
          );
          statusAtRequest.add(
            rows.isEmpty ? null : rows.single['sync_status'] as String?,
          );
          final failure = failWith;
          if (failure != null) throw failure;
        },
      );
    });

    test('add, update, End and delete each ask for one sync after the local '
        'write', () async {
      await repo.addTreatment(episode.toDomain());
      await pumpEventQueue();
      expect(statusAtRequest, [SyncStatus.pendingCreate]);

      final added = (await repo.getTreatmentById('t1')).dataOrNull!;
      await repo.updateTreatment(added.copyWith(notes: 'edited'));
      await pumpEventQueue();
      expect(statusAtRequest.last, SyncStatus.pendingUpdate);

      await repo.endTreatment('t1');
      await pumpEventQueue();
      expect(statusAtRequest.last, SyncStatus.pendingUpdate);

      await repo.deleteTreatment('t1');
      await pumpEventQueue();
      expect(statusAtRequest, [
        SyncStatus.pendingCreate,
        SyncStatus.pendingUpdate,
        SyncStatus.pendingUpdate,
        SyncStatus.pendingDelete,
      ]);
    });

    test('a failed sync request does not fail the write', () async {
      failWith = StateError('offline');
      await local.upsert(episode, syncStatus: SyncStatus.synced);

      final result = await repo.endTreatment('t1');
      await pumpEventQueue();

      expect(result.isSuccess, isTrue);
      expect(await syncStatus('t1'), SyncStatus.pendingUpdate);
    });

    test(
      'a request that throws synchronously does not fail the write',
      () async {
        final throwing = TreatmentRepositoryImpl(
          localDatasource: local,
          requestSync: () => throw StateError('provider disposed'),
        );
        await local.upsert(episode, syncStatus: SyncStatus.synced);

        final result = await throwing.endTreatment('t1');

        expect(result.isSuccess, isTrue);
        expect(await syncStatus('t1'), SyncStatus.pendingUpdate);
      },
    );

    test('a failed End asks for no sync', () async {
      await local.upsert(episode, syncStatus: SyncStatus.synced);
      await local.markDeleted('t1');

      await repo.endTreatment('t1');
      await repo.endTreatment('missing');
      await pumpEventQueue();

      expect(statusAtRequest, isEmpty);
    });
  });
}
