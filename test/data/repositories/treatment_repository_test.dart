import 'dart:async';

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
    String? signedInUser;

    setUp(() {
      signedInUser = 'user-a';
      // The server stamps `updated_at` with its own clock on every update,
      // as the `update_updated_at` trigger does. Real time keeps it in step
      // with the `DateTime.now()` the repository stamps local edits with.
      remote = FakeTreatmentRemote(() => DateTime.now().toUtc());
      repo = TreatmentRepositoryImpl(
        localDatasource: local,
        remoteDatasource: remote,
        currentUserId: () => signedInUser,
      );
    });

    /// The server copy of [episode] as it was before the sick leave was
    /// recorded, stamped long before any edit this test makes.
    void seedServerBeforeSickLeave() => remote.table.seed(
      TreatmentModel(
        id: 't1',
        userId: 'user-a',
        name: 'Stirnhöhlenentzündung',
        startDate: DateTime(2026, 3, 2),
        notes: 'ging langsam weg',
      ).toJson(),
      updatedAt: DateTime.utc(2026, 3, 2, 8),
    );

    test('endTreatment pushes the whole row, not just the end flags', () async {
      // The server still has the episode as it was before the sick leave
      // was recorded; the sick-leave edit is only pending locally (it was
      // made offline).
      seedServerBeforeSickLeave();
      await local.upsert(episode, syncStatus: SyncStatus.pendingUpdate);

      final result = await repo.endTreatment('t1');
      expect(result.isSuccess, isTrue);
      await repo.backgroundSyncIdle;
      expect(await syncStatus('t1'), SyncStatus.synced);

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

    test('endTreatment leaves a newer server row alone and stays pending '
        '(last write wins)', () async {
      // This device still holds the pre-edit copy ...
      await local.upsert(episode, syncStatus: SyncStatus.synced);
      // ... while another device recorded a new certificate number, and the
      // server stamped that edit later than this device's End will be.
      remote.table.seed({
        ...episode.toJson(),
        'user_id': 'user-a',
        'notes': 'edited on the other phone',
        'sick_leave_ref': 'A-REF',
      }, updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)));

      final result = await repo.endTreatment('t1');
      expect(result.isSuccess, isTrue);
      await repo.backgroundSyncIdle;

      final row = remote.table.rows['t1']!;
      expect(row['notes'], 'edited on the other phone');
      expect(row['sick_leave_ref'], 'A-REF');
      expect(row['is_active'], isTrue);
      // Left for the sync cycle, which pulls the winner.
      expect(await syncStatus('t1'), SyncStatus.pendingUpdate);
    });

    test('an edit made while the End push is in flight reaches the server '
        'and is not lost', () async {
      seedServerBeforeSickLeave();
      await local.upsert(episode, syncStatus: SyncStatus.synced);

      // Hold the first upsert (End's) on a slow network; let later ones by.
      final release = Completer<void>();
      final endPushStarted = Completer<void>();
      var upserts = 0;
      remote.table.beforeCall = () async {
        if (upserts++ > 0) return;
        endPushStarted.complete();
        await release.future;
      };

      await repo.endTreatment('t1');
      await endPushStarted.future;

      final ended = (await repo.getTreatmentById('t1')).dataOrNull!;
      await repo.updateTreatment(ended.copyWith(notes: 'new note'));
      // Give an unserialised edit push every chance to land first.
      await pumpEventQueue();

      release.complete();
      await repo.backgroundSyncIdle;

      final stored = (await local.getTreatmentById('t1'))!;
      final row = remote.table.rows['t1']!;
      expect(stored.notes, 'new note');
      expect(row['notes'], 'new note');
      expect(row['is_active'], isFalse);
      expect(await syncStatus('t1'), SyncStatus.synced);
    });

    test(
      'a delete made while the End push is in flight stays pending',
      () async {
        seedServerBeforeSickLeave();
        await local.upsert(episode, syncStatus: SyncStatus.synced);

        final release = Completer<void>();
        final endPushStarted = Completer<void>();
        remote.table.beforeCall = () async {
          endPushStarted.complete();
          await release.future;
        };

        await repo.endTreatment('t1');
        await endPushStarted.future;
        // The delete's own push is not sent right away (here: signed out
        // meanwhile), so only the pending status carries it to the next sync.
        signedInUser = null;
        await repo.deleteTreatment('t1');

        release.complete();
        await repo.backgroundSyncIdle;

        // markDeleted does not move updated_at, so the End push's copy still
        // matches it; the pending delete must not be marked synced anyway.
        expect(await syncStatus('t1'), SyncStatus.pendingDelete);
      },
    );

    test('the push stamps the signed-in user, not the local user_id', () async {
      seedServerBeforeSickLeave();
      // Created in local-only mode: no owner recorded yet.
      await local.upsert(episode, syncStatus: SyncStatus.synced);

      await repo.endTreatment('t1');
      await repo.backgroundSyncIdle;

      expect(remote.table.rows['t1']!['user_id'], 'user-a');
      expect(await syncStatus('t1'), SyncStatus.synced);
    });

    test('nothing is pushed while nobody is signed in', () async {
      signedInUser = null;
      seedServerBeforeSickLeave();
      await local.upsert(episode, syncStatus: SyncStatus.synced);

      await repo.endTreatment('t1');
      await repo.backgroundSyncIdle;

      expect(remote.table.rows['t1']!['is_active'], isTrue);
      expect(await syncStatus('t1'), SyncStatus.pendingUpdate);
    });

    test('endTreatment creates the server row when the server has none '
        '(upsert, not update)', () async {
      await local.upsert(episode, syncStatus: SyncStatus.pendingCreate);

      await repo.endTreatment('t1');
      await repo.backgroundSyncIdle;

      final row = remote.table.rows['t1'];
      expect(row, isNotNull);
      expect(row!['is_active'], isFalse);
      expect(row['sick_leave_ref'], '1234567890');
      expect(await syncStatus('t1'), SyncStatus.synced);
    });

    test(
      'updateTreatment creates the server row when the server has none',
      () async {
        await local.upsert(episode, syncStatus: SyncStatus.pendingCreate);
        final treatment = (await repo.getTreatmentById('t1')).dataOrNull!;

        await repo.updateTreatment(treatment.copyWith(notes: 'edited'));
        await repo.backgroundSyncIdle;

        expect(remote.table.rows['t1']?['notes'], 'edited');
        expect(await syncStatus('t1'), SyncStatus.synced);
      },
    );
  });
}
