/// The treatment write path end to end: the repository writes locally and
/// asks for a sync cycle, and the cycle is the only thing that pushes.
///
/// The fake server stamps `updated_at` with its own clock on every update, as
/// the `update_updated_at` trigger does; [_Rig.serverSkew] makes that clock
/// run ahead of the device's.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/services/sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthClientOptions, SupabaseClient;

import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

class _Rig {
  _Rig({
    this.serverSkew = Duration.zero,
    FakeTreatmentRemote Function(DateTime Function() clock)? treatmentRemote,
  }) {
    DateTime serverNow() => DateTime.now().toUtc().add(serverSkew);
    remote = (treatmentRemote ?? FakeTreatmentRemote.new)(serverNow);
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: FakeMedicationRemote(serverNow),
      treatmentLocal: local,
      treatmentRemote: remote,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: FakePrescriptionRemote(serverNow),
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: FakeDoseLogRemote(serverNow),
      familyLocal: FamilyLocalDatasource(),
      familyRemote: FakeFamilyRemote(serverNow),
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
    );
    repo = TreatmentRepositoryImpl(
      localDatasource: local,
      requestSync: () {
        final cycle = service.syncAll();
        _requests.add(cycle);
        return cycle;
      },
    );
  }

  final Duration serverSkew;
  final local = TreatmentLocalDatasource();
  late final FakeTreatmentRemote remote;
  late final SyncService service;
  late final TreatmentRepositoryImpl repo;
  bool online = true;
  final List<Future<void>> _requests = [];

  /// Completes once every sync cycle the repository asked for has finished,
  /// queued re-runs included.
  Future<void> idle() async {
    while (_requests.isNotEmpty) {
      final pending = List.of(_requests);
      _requests.clear();
      await Future.wait(pending);
    }
  }

  /// Holds the first call into the treatments fake (a cycle's push, when a
  /// row is pending) until [release] completes. Every later call runs through
  /// [after], when given.
  Future<void> holdFirstCall(
    Future<void> release, {
    Completer<void>? started,
    Future<void> Function(int call)? after,
  }) async {
    var calls = 0;
    remote.table.beforeCall = () async {
      final call = calls++;
      if (call == 0) {
        started?.complete();
        await release;
        return;
      }
      await after?.call(call);
    };
  }

  Future<Map<String, dynamic>> localRow(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('treatments', where: 'id = ?', whereArgs: [id]);
    return rows.single;
  }
}

/// A server that has not had `20260917000000_treatment_sick_leave.sql`
/// applied: every treatment push goes through the real datasource, and
/// PostgREST answers PGRST204 for the first sick-leave key. Reads still come
/// from the fake table. No Supabase project is contacted.
class _UnmigratedTreatmentRemote extends FakeTreatmentRemote {
  _UnmigratedTreatmentRemote(super.clock) {
    _client = SupabaseClient(
      'http://supabase.invalid',
      'anon-key',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'code': 'PGRST204',
            'message':
                "Could not find the 'doctor' column of 'treatments' in the "
                'schema cache',
          }),
          400,
          headers: {'content-type': 'application/json'},
          // PostgREST's client reads the method off the answer's request.
          request: request,
        ),
      ),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(_client.dispose);
  }

  late final SupabaseClient _client;

  @override
  Future<DateTime?> upsertTreatment(TreatmentModel model) =>
      TreatmentRemoteDatasource(_client).upsertTreatment(model);
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final longAgo = DateTime.utc(2026, 3, 2, 8);

  final episode = TreatmentModel(
    id: 't1',
    userId: 'user-a',
    name: 'Stirnhöhlenentzündung',
    patientTags: const ['Ben'],
    symptomTags: const ['Kopfschmerzen'],
    startDate: DateTime(2026, 3, 2),
    notes: 'ging langsam weg',
    sickLeaveFrom: DateTime(2026, 3, 3),
    sickLeaveTo: DateTime(2026, 3, 9),
    sickLeaveRef: '1234567890',
    doctor: 'Dr. Rossi, Bozen',
    createdAt: longAgo,
    updatedAt: longAgo,
  );

  /// The server and this device agree on [episode], last synced long ago.
  Future<void> seedInSync(_Rig r) async {
    r.remote.table.seed(episode.toJson(), updatedAt: longAgo);
    await r.local.upsert(episode, syncStatus: SyncStatus.synced);
  }

  test('End sends every column, sick leave included', () async {
    final r = _Rig();
    // The server still has the episode as it was before the sick leave was
    // recorded; the sick-leave edit is only pending locally (made offline).
    r.remote.table.seed(
      TreatmentModel(
        id: 't1',
        userId: 'user-a',
        name: 'Stirnhöhlenentzündung',
        startDate: DateTime(2026, 3, 2),
        notes: 'ging langsam weg',
      ).toJson(),
      updatedAt: longAgo.subtract(const Duration(hours: 1)),
    );
    await r.local.upsert(episode, syncStatus: SyncStatus.pendingUpdate);

    expect((await r.repo.endTreatment('t1')).isSuccess, isTrue);
    await r.idle();

    final row = r.remote.table.rows['t1']!;
    expect(row['sick_leave_from'], '2026-03-03');
    expect(row['sick_leave_to'], '2026-03-09');
    expect(row['sick_leave_ref'], '1234567890');
    expect(row['doctor'], 'Dr. Rossi, Bozen');
    expect(row['notes'], 'ging langsam weg');
    expect(row['patient_tags'], '["Ben"]');
    expect(row['is_active'], isFalse);
    expect(row['end_date'], isNotNull);
    expect((await r.localRow('t1'))['sync_status'], SyncStatus.synced);
  });

  test('a project without the sick-leave migration reports the file to '
      'apply, and the row stays pending (I-2)', () async {
    final r = _Rig(treatmentRemote: _UnmigratedTreatmentRemote.new);
    await r.local.upsert(episode, syncStatus: SyncStatus.pendingCreate);

    await r.service.syncAll();

    final failures = r.service.lastReport!.failures;
    expect(failures, hasLength(1));
    expect(failures.single.table, 'treatments');
    expect(failures.single.id, 't1');
    // The text the settings failures dialog shows for the row.
    expect(
      failures.single.error,
      allOf(
        startsWith('push: '),
        contains('treatments.doctor'),
        contains('supabase/migrations/20260917000000_treatment_sick_leave.sql'),
      ),
    );
    expect((await r.localRow('t1'))['sync_status'], SyncStatus.pendingCreate);
    expect(r.remote.table.rows, isEmpty);
  });

  test('End leaves the prescriptions and their doses as they were, and '
      'pushes nothing for them (review I-3)', () async {
    final r = _Rig();
    await seedInSync(r);
    final db = await AppDatabase.instance.database;
    const stamp = '2026-03-02T08:00:00.000Z';
    await db.insert('medications', {
      'id': 'm1',
      'name': 'Ibuprofen',
      'quantity': 10,
      'quantity_unit': 'tablets',
      'minimum_stock_level': 0,
      'created_at': stamp,
      'updated_at': stamp,
      'sync_status': SyncStatus.synced,
    });
    await db.insert('prescriptions', {
      'id': 'p1',
      'treatment_id': 't1',
      'medication_id': 'm1',
      'dosage': '1 tablet',
      'dosage_amount': 1.0,
      'interval_hours': 8,
      'duration_days': 7,
      'start_time': '2026-03-02T08:00:00.000',
      'is_active': 1,
      'auto_diminish': 0,
      'schedule_type': 'fixed_interval',
      'created_at': stamp,
      'updated_at': stamp,
      'sync_status': SyncStatus.synced,
    });
    for (final (id, status) in [('d1', 'taken'), ('d2', 'pending')]) {
      await db.insert('dose_logs', {
        'id': id,
        'prescription_id': 'p1',
        'scheduled_time': '2026-03-02T${id == 'd1' ? '08' : '16'}:00:00.000',
        'status': status,
        'created_at': stamp,
        'updated_at': stamp,
        'sync_status': SyncStatus.synced,
      });
    }
    Future<List<Map<String, Object?>>> rows(String table) =>
        db.query(table, orderBy: 'id');
    final medicationsBefore = await rows('medications');
    final prescriptionsBefore = await rows('prescriptions');
    final dosesBefore = await rows('dose_logs');

    await r.repo.endTreatment('t1');
    await r.idle();

    expect(r.remote.table.rows['t1']!['is_active'], isFalse);
    expect(await rows('medications'), medicationsBefore);
    expect(await rows('prescriptions'), prescriptionsBefore);
    expect(await rows('dose_logs'), dosesBefore);
    expect(r.service.lastReport?.pushed, 1);
  });

  test('End creates the server row when the server has none', () async {
    final r = _Rig();
    await r.local.upsert(episode, syncStatus: SyncStatus.pendingCreate);

    await r.repo.endTreatment('t1');
    await r.idle();

    final row = r.remote.table.rows['t1'];
    expect(row?['is_active'], isFalse);
    expect(row?['sick_leave_ref'], '1234567890');
    expect((await r.localRow('t1'))['sync_status'], SyncStatus.synced);
  });

  test('End does not overwrite a newer server row from another device '
      '(last write wins)', () async {
    final r = _Rig();
    // This device still holds the pre-edit copy ...
    await r.local.upsert(episode, syncStatus: SyncStatus.synced);
    // ... while another device recorded a new certificate number, and the
    // server stamped that edit later than this device's End will be.
    r.remote.table.seed({
      ...episode.toJson(),
      'notes': 'edited on the other phone',
      'sick_leave_ref': 'A-REF',
    }, updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)));

    await r.repo.endTreatment('t1');
    await r.idle();

    final row = r.remote.table.rows['t1']!;
    expect(row['notes'], 'edited on the other phone');
    expect(row['sick_leave_ref'], 'A-REF');
    expect(row['is_active'], isTrue);
    expect(r.service.lastReport?.skippedStale, 1);
    // The cycle's pull brought the winner home.
    final stored = (await r.local.getTreatmentById('t1'))!;
    expect(stored.sickLeaveRef, 'A-REF');
    expect((await r.localRow('t1'))['sync_status'], SyncStatus.synced);
  });

  test('an edit made while the cycle pushes the row stays pending, survives '
      "the cycle's pull, and reaches the server on the re-run (I-3)", () async {
    final r = _Rig();
    await seedInSync(r);

    final release = Completer<void>();
    final pushStarted = Completer<void>();
    String? statusAtFirstPull;
    String? notesAtFirstPull;
    await r.holdFirstCall(
      release.future,
      started: pushStarted,
      after: (call) async {
        // Call 1 is the first cycle's pull, right after the End push landed.
        if (call != 1) return;
        final row = await r.localRow('t1');
        statusAtFirstPull = row['sync_status'] as String?;
        notesAtFirstPull = row['notes'] as String?;
      },
    );

    await r.repo.endTreatment('t1');
    await pushStarted.future;
    final ended = (await r.repo.getTreatmentById('t1')).dataOrNull!;
    await r.repo.updateTreatment(ended.copyWith(notes: 'new note'));
    release.complete();
    await r.idle();

    // The End push carried the pre-edit copy, so the row was not synced.
    expect(statusAtFirstPull, SyncStatus.pendingUpdate);
    expect(notesAtFirstPull, 'new note');

    final row = r.remote.table.rows['t1']!;
    expect(row['notes'], 'new note');
    expect(row['is_active'], isFalse);
    final stored = await r.localRow('t1');
    expect(stored['notes'], 'new note');
    expect(stored['is_active'], 0);
    expect(stored['sync_status'], SyncStatus.synced);
  });

  test(
    'an interrupted push followed by a later sync keeps the edit (I-1)',
    () async {
      final r = _Rig();
      await seedInSync(r);

      final release = Completer<void>();
      final pushStarted = Completer<void>();
      var networkDown = false;
      await r.holdFirstCall(
        release.future,
        started: pushStarted,
        after: (_) async {
          if (networkDown) throw StateError('network down');
        },
      );

      // End goes out on a slow network; the user adds a note meanwhile; the
      // End upsert lands and the connection drops right after it.
      await r.repo.endTreatment('t1');
      await pushStarted.future;
      final ended = (await r.repo.getTreatmentById('t1')).dataOrNull!;
      await r.repo.updateTreatment(ended.copyWith(notes: 'new note'));
      networkDown = true;
      r.online = false;
      release.complete();
      await r.idle();

      expect(r.remote.table.rows['t1']!['is_active'], isFalse);
      var stored = await r.localRow('t1');
      expect(stored['notes'], 'new note');
      expect(stored['sync_status'], SyncStatus.pendingUpdate);

      // Later (the next app start, a reconnect): a plain cycle.
      networkDown = false;
      r.online = true;
      await r.service.syncAll();

      expect(r.remote.table.rows['t1']!['notes'], 'new note');
      expect(r.remote.table.rows['t1']!['is_active'], isFalse);
      stored = await r.localRow('t1');
      expect(stored['notes'], 'new note');
      expect(stored['is_active'], 0);
      expect(stored['sync_status'], SyncStatus.synced);
    },
  );

  group('device clock behind the server (I-2)', () {
    const skew = Duration(minutes: 2);

    test('End shortly after a synced edit survives the next sync', () async {
      final r = _Rig(serverSkew: skew);
      await seedInSync(r);

      final treatment = (await r.repo.getTreatmentById('t1')).dataOrNull!;
      await r.repo.updateTreatment(treatment.copyWith(sickLeaveRef: 'NEW'));
      await r.idle();
      expect(r.remote.table.rows['t1']!['sick_leave_ref'], 'NEW');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await r.repo.endTreatment('t1');
      await r.idle();
      await r.service.syncAll();

      expect(r.remote.table.rows['t1']!['is_active'], isFalse);
      expect(r.remote.table.rows['t1']!['sick_leave_ref'], 'NEW');
      final stored = await r.localRow('t1');
      expect(stored['is_active'], 0);
      expect(stored['sync_status'], SyncStatus.synced);
    });

    test('End tapped while the edit\'s cycle is still running survives '
        'the sync', () async {
      final r = _Rig(serverSkew: skew);
      await seedInSync(r);

      // Hold the edit cycle's pull, after its push has landed.
      final releasePull = Completer<void>();
      final pullStarted = Completer<void>();
      var calls = 0;
      r.remote.table.beforeCall = () async {
        if (calls++ != 1) return;
        pullStarted.complete();
        await releasePull.future;
      };

      final treatment = (await r.repo.getTreatmentById('t1')).dataOrNull!;
      await r.repo.updateTreatment(treatment.copyWith(sickLeaveRef: 'NEW'));
      await pullStarted.future;
      await r.repo.endTreatment('t1');
      releasePull.complete();
      await r.idle();
      await r.service.syncAll();

      expect(r.remote.table.rows['t1']!['is_active'], isFalse);
      expect(r.remote.table.rows['t1']!['sick_leave_ref'], 'NEW');
      final stored = await r.localRow('t1');
      expect(stored['is_active'], 0);
      expect(stored['sick_leave_ref'], 'NEW');
      expect(stored['sync_status'], SyncStatus.synced);
    });
  });

  test('a delete made while the cycle pushes an End wins', () async {
    final r = _Rig();
    await seedInSync(r);

    final release = Completer<void>();
    final pushStarted = Completer<void>();
    await r.holdFirstCall(release.future, started: pushStarted);

    await r.repo.endTreatment('t1');
    await pushStarted.future;
    await r.repo.deleteTreatment('t1');
    // markDeleted does not move updated_at, so the End push's copy still
    // matches it; the pending delete must not be marked synced anyway.
    release.complete();
    await r.idle();

    expect(r.remote.table.rows['t1']!['deleted_at'], isNotNull);
    expect(await r.local.getTreatmentById('t1'), isNull);
  });
}
