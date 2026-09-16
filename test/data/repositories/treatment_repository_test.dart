import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';

import '../../helpers/fake_remotes.dart';
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
        remoteDatasource: null, // local-only: no background push
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

    test('endTreatment on a missing id fails instead of writing', () async {
      final result = await repo.endTreatment('nope');
      expect(result.isFailure, isTrue);
      expect(await local.getTreatments(), isEmpty);
    });
  });

  group('with a remote', () {
    late FakeTreatmentRemote remote;
    late TreatmentRepositoryImpl repo;

    setUp(() {
      remote = FakeTreatmentRemote(() => DateTime.utc(2026, 3, 11, 12));
      repo = TreatmentRepositoryImpl(
        localDatasource: local,
        remoteDatasource: remote,
      );
    });

    /// Lets the fire-and-forget background push run to completion.
    Future<void> settleBackgroundSync() async {
      for (var i = 0; i < 50; i++) {
        if (await syncStatus('t1') == SyncStatus.synced) return;
        await pumpEventQueue();
      }
      fail('the background push never marked t1 synced');
    }

    test('endTreatment pushes the whole row, not just the end flags', () async {
      // The server still has the episode as it was before the sick leave
      // was recorded; the sick-leave edit is only pending locally (it was
      // made offline).
      remote.table.seed(
        TreatmentModel(
          id: 't1',
          name: 'Stirnhöhlenentzündung',
          startDate: DateTime(2026, 3, 2),
        ).toJson(),
        updatedAt: DateTime.utc(2026, 3, 2, 8),
      );
      await local.upsert(episode, syncStatus: SyncStatus.pendingUpdate);

      final result = await repo.endTreatment('t1');
      expect(result.isSuccess, isTrue);
      await settleBackgroundSync();

      // The row is now marked synced locally, so whatever the push left out
      // would never reach the server. It must therefore carry everything.
      final row = remote.table.rows['t1']!;
      expect(row['sick_leave_from'], '2026-03-03');
      expect(row['sick_leave_to'], '2026-03-09');
      expect(row['sick_leave_ref'], '1234567890');
      expect(row['doctor'], 'Dr. Rossi, Bozen');
      expect(row['notes'], 'ging langsam weg');
      expect(row['is_active'], isFalse);
      expect(row['end_date'], isNotNull);
    });
  });
}
