/// How many requests a cycle costs when many rows change at once: a
/// sign-in that marks every row for upload, a sweep of overdue doses on
/// two devices, the first day after the upgrade, and a changed schedule.
/// Each is a small number of paged requests per table, never one per row
/// (cycle review I-4 and I-5), and each still follows the sync rules: a
/// person's change on another device beats the app's own.
///
/// Two devices on one account, each with its own SQLite file, repositories
/// and cycle, and one fake server that counts every request.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

/// A device that upgraded: its first cycle is the repair pull.
class _UpgradedCursors extends SyncCursorStore {
  _UpgradedCursors() : super.inMemory();
  var _done = false;

  @override
  Future<bool> startPullRepair() async => !_done;

  @override
  Future<void> finishPullRepair() async => _done = true;
}

class _Device {
  _Device(this.name, this.path, this.server, {SyncCursorStore? cursors})
    : cursors = cursors ?? SyncCursorStore.inMemory() {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: prescriptionLocal,
      prescriptionRemote: server.prescriptions,
      doseLogLocal: doseLogLocal,
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: this.cursors,
      failures: failures,
      capRetryDelay: const Duration(days: 1),
      onPrescriptionsPulled: (pulled) => schedule.applyPulled(pulled),
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: doseLogLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
    );
    schedule = DoseScheduleService(
      prescriptions: PrescriptionRepositoryImpl(
        localDatasource: prescriptionLocal,
      ),
      doses: doses,
    );
  }

  final String name;
  final String path;
  final FakeServer server;
  bool online = true;
  final SyncCursorStore cursors;
  final failures = SyncFailureStore.inMemory();
  final prescriptionLocal = PrescriptionLocalDatasource();
  final doseLogLocal = DoseLogLocalDatasource();
  late final SyncService service;
  late final DoseLogRepositoryImpl doses;
  late final DoseScheduleService schedule;
  final List<Future<void>> _requests = [];
  final List<SyncReport> reports = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll().then((r) {
      if (r != null) reports.add(r);
    });
    _requests.add(cycle);
    return cycle;
  }

  /// Opens this device's database, runs [body], and waits for every sync
  /// the body asked for.
  Future<T> run<T>(Future<T> Function(Database db) body) async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = path;
    final result = await body(await AppDatabase.instance.database);
    await pumpEventQueue();
    while (_requests.isNotEmpty) {
      final pending = List.of(_requests);
      _requests.clear();
      await Future.wait(pending);
      await pumpEventQueue();
    }
    await Future<void>.delayed(const Duration(milliseconds: 3));
    return result;
  }

  Future<void> sync() => run((_) => _requestSync());

  Future<void> sweep() =>
      run((_) => doses.markOverduePendingAsMissed(DateTime.now()));

  Future<int> count(String where) => run(
    (db) async =>
        (await db.rawQuery(
              'SELECT COUNT(*) AS n FROM dose_logs WHERE $where',
            )).first['n']!
            as int,
  );

  Future<Map<String, Object?>> dose(String id) => run(
    (db) async =>
        (await db.query('dose_logs', where: 'id = ?', whereArgs: [id])).single,
  );

  Future<void> markAllForUpload() => run((_) async {
    await LocalUploadMarker(
      database: AppDatabase.instance,
      cursors: cursors,
      prefs: await SharedPreferences.getInstance(),
    ).markAllForUpload('user-a');
  });
}

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  late Directory dir;
  late FakeServer server;
  late _Device a;
  late _Device b;
  late String prescriptionId;

  /// The requests [body] made, with the single-row reads counted apart.
  Future<({int all, int singleReads, int writes})> requests(
    Future<void> Function() body,
  ) async {
    final before = server.core.requests.length;
    await body();
    final made = server.core.requests.sublist(before);
    return (
      all: made.length,
      singleReads: made.where((r) => r.endsWith(':fetch')).length,
      writes: made
          .where(
            (r) =>
                r.endsWith(':patch') ||
                r.endsWith(':patchMany') ||
                r.endsWith(':insert'),
          )
          .length,
    );
  }

  Map<String, Object?> versions() => {
    for (final MapEntry(key: id, value: r) in server.doses.table.rows.entries)
      id: r['row_version'],
  };

  /// [device] makes a prescription for half a year in the past and half a
  /// year to come, twice a day, and keeps it on this device only.
  Future<void> createYear(_Device device) async {
    await device.run((db) async {
      final seeded = await seedPrescription(
        db,
        startTime: DateTime(today.year, today.month, today.day - 180, 8),
        durationDays: 365,
        scheduleType: 'times_per_day',
      );
      prescriptionId = seeded.prescriptionId;
      await db.update(
        'prescriptions',
        {
          'schedule_times': '["08:00","20:00"]',
          'sync_status': SyncStatus.pendingCreate,
        },
        where: 'id = ?',
        whereArgs: [seeded.prescriptionId],
      );
      for (final (table, id) in [
        ('medications', seeded.medicationId),
        ('treatments', seeded.treatmentId),
      ]) {
        await db.update(
          table,
          {'sync_status': SyncStatus.pendingCreate},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await device.doses.generateDoseLogsForPrescription(prescriptionId);
    });
  }

  Future<void> expectSettled(List<_Device> devices) async {
    for (final device in devices) {
      expect(
        await device.count("sync_status != 'synced'"),
        0,
        reason: '${device.name}: nothing left to send',
      );
    }
    final before = versions();
    final quiet = await requests(() async {
      for (final device in devices) {
        await device.sync();
      }
    });
    expect(quiet.writes, 0, reason: 'a quiet round writes nothing');
    expect(versions(), before);
  }

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('medora_request_count_');
    server = FakeServer(() => DateTime.now().toUtc());
    a = _Device('A', '${dir.path}/a.db', server);
    b = _Device('B', '${dir.path}/b.db', server);
  });

  tearDown(() async {
    a.service.dispose();
    b.service.dispose();
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  group('a year of doses', () {
    setUp(() async {
      a.online = false;
      await createYear(a);
      a.online = true;
      await a.sync();
      await b.sync();
      expect(server.doses.table.rows, hasLength(730));
    });

    test('signing in again reads every table in pages and sends nothing '
        'unchanged', () async {
      await a.markAllForUpload();
      final cost = await requests(a.sync);
      expect(cost.singleReads, 0);
      expect(cost.writes, 0);
      // The state read, 8 dose reads, one each for the three other tables,
      // and the pull (every table from the start, then an empty page).
      expect(cost.all, lessThanOrEqualTo(20));
      await expectSettled([a, b]);
    });

    test('signing in again keeps a change made while signed out, and takes '
        'the other device\'s newer one', () async {
      final mine = scheduledDoseId(
        prescriptionId,
        DateTime(today.year, today.month, today.day + 3, 8),
      );
      final theirs = scheduledDoseId(
        prescriptionId,
        DateTime(today.year, today.month, today.day + 4, 8),
      );
      a.online = false;
      await a.run((_) => a.doses.markDoseSkipped(mine));
      a.online = true;
      await b.run((_) => b.doses.markDoseTaken(theirs));
      await a.markAllForUpload();
      final cost = await requests(a.sync);
      expect(cost.singleReads, 0);
      expect(cost.writes, 1, reason: 'only the skip goes out');
      expect(server.doses.table.rows[mine]!['status'], 'skipped');
      expect((await a.dose(theirs))['status'], 'taken');
      await b.sync();
      expect((await b.dose(mine))['status'], 'skipped');
      await expectSettled([a, b]);
    });

    test('writes that never reached the server are read again in bulk, not '
        'one by one', () async {
      final ids = [
        for (var day = 1; day <= 60; day++)
          scheduledDoseId(
            prescriptionId,
            DateTime(today.year, today.month, today.day + day, 8),
          ),
      ];
      // The server refuses these writes before anything lands; each row
      // keeps the write id it stored before sending.
      server.doses.table.failIds.addAll(ids);
      for (final id in ids) {
        await a.run((_) => a.doses.markDoseTaken(id));
      }
      expect(
        await a.count(
          "sync_write_id IS NOT NULL AND sync_status = 'pending_update'",
        ),
        60,
      );
      server.doses.table.failIds.clear();
      await a.failures.clearAll();
      final cost = await requests(a.sync);
      expect(cost.singleReads, 0);
      expect(cost.writes, 60, reason: 'one take each');
      expect(
        server.doses.table.rows.values.where((r) => r['status'] == 'taken'),
        hasLength(60),
      );
      await expectSettled([a, b]);
    });

    test('a bulk request that fails backs its rows off instead of sending '
        'them one by one', () async {
      final overdue = await a.count(
        "status = 'pending' AND scheduled_time < '${DateTime.now().toIso8601String()}'",
      );
      final first = scheduledDoseId(
        prescriptionId,
        DateTime(today.year, today.month, today.day - 180, 8),
      );
      // The server refuses the bulk write that names the oldest dose.
      server.doses.table.failIds.add(first);
      final sweep = await requests(a.sweep);
      expect(
        server.core.requests.where((r) => r == 'dose_logs:patch'),
        isEmpty,
        reason: 'no dose of the failed request is sent on its own',
      );
      expect(sweep.writes, (overdue / 100).ceil() - 1, reason: 'the others');
      expect(
        a.reports.expand((r) => r.failures).map((f) => f.id).toSet(),
        hasLength(100),
      );
      expect(await a.count("sync_status = 'pending_update'"), 100);

      // A bulk read that fails backs its rows off the same way.
      server.doses.table.failIds.clear();
      await a.failures.clearAll();
      await a.markAllForUpload();
      server.doses.table.failGetIds.add(first);
      final read = await requests(a.sync);
      expect(read.singleReads, 0);
      server.doses.table.failGetIds.clear();
      await a.failures.clearAll();
      await a.sync();
      await expectSettled([a, b]);
    });

    test('the overdue sweep goes out in bulk; the same sweep on the other '
        'device writes nothing; a take made there first wins', () async {
      final taken = scheduledDoseId(
        prescriptionId,
        DateTime(today.year, today.month, today.day - 10, 8),
      );
      // B takes a past dose before A sweeps; A has not pulled it.
      await b.run((_) => b.doses.markDoseTaken(taken));
      final overdue = await a.count(
        "status = 'pending' AND scheduled_time < '${DateTime.now().toIso8601String()}'",
      );
      expect(overdue, greaterThan(300));

      final onA = await requests(a.sweep);
      expect(onA.singleReads, 0);
      // One conditional write per 100 doses, and one read for those it
      // did not write (the take), then the pull.
      expect(onA.writes, (overdue / 100).ceil());
      expect(onA.all, lessThanOrEqualTo((overdue / 100).ceil() + 10));
      expect(server.doses.table.rows[taken]!['status'], 'taken');
      expect((await a.dose(taken))['status'], 'taken');
      expect(
        server.doses.table.rows.values
            .where((r) => r['status'] == 'missed')
            .length,
        overdue - 1,
      );
      final missed = server.doses.table.rows.values.firstWhere(
        (r) => r['status'] == 'missed',
      );
      expect(missed['edited_at'], startsWith('1970-01-01'));
      expect(missed['write_id'], isNotNull);

      // B swept the same doses offline before it heard of A's.
      b.online = false;
      await b.sweep();
      b.online = true;
      final before = versions();
      final onB = await requests(b.sync);
      expect(onB.singleReads, 0);
      expect(versions(), before, reason: 'no dose written again');
      expect(onB.all, lessThanOrEqualTo(2 * (overdue / 100).ceil() + 10));
      expect(await b.count("status = 'missed'"), overdue - 1);
      await expectSettled([a, b]);
    });

    test('an undo on the other device beats a sweep made from an older '
        'copy', () async {
      final undone = scheduledDoseId(
        prescriptionId,
        DateTime(today.year, today.month, today.day - 2, 20),
      );
      // A hears nothing of B's take and B's later undo.
      a.online = false;
      await b.run((_) => b.doses.markDoseTaken(undone));
      await b.run((_) => b.doses.markDosePending(undone));
      await a.sweep();
      a.online = true;
      await a.sync();
      expect(server.doses.table.rows[undone]!['status'], 'pending');
      final onA = await a.dose(undone);
      expect([onA['status'], onA['sync_status']], ['pending', 'synced']);
      expect(
        server.doses.table.rows.values
            .where((r) => r['status'] == 'missed')
            .length,
        greaterThan(300),
      );
      await b.sync();
      await expectSettled([a, b]);
    });

    test('a schedule change drops half a year of doses in bulk', () async {
      final cost = await requests(
        () => a.run((db) async {
          await db.update(
            'prescriptions',
            {
              'schedule_times': '["09:00","21:00"]',
              'sync_status': SyncStatus.pendingUpdate,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [prescriptionId],
          );
          await a.doses.regenerateDoseLogsForPrescription(prescriptionId);
        }),
      );
      final live = server.doses.table.rows.values
          .where((r) => r['deleted_at'] == null)
          .toList();
      expect(live, hasLength(730));
      final dropped = server.doses.table.rows.values
          .where((r) => r['deleted_at'] != null)
          .toList();
      expect(dropped, hasLength(730));
      expect(
        dropped.every((r) => (r['edited_at']! as String).startsWith('1970')),
        isTrue,
      );
      expect(cost.singleReads, 0);
      // One prescription patch, 8 drops, 8 inserts of the new doses with
      // their reads, and the pull.
      expect(cost.all, lessThanOrEqualTo(40));
      await b.sync();
      await b.run((_) => b.schedule.ensureScheduled());
      await expectSettled([a, b]);
    });
  });

  test('a device with a year of local doses signs in for the first time: '
      'they go out in batches', () async {
    a.online = false;
    await createYear(a);
    a.online = true;
    await a.run((db) async {
      for (final t in [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        await db.update(t, {'sync_status': SyncStatus.synced});
      }
    });
    await a.markAllForUpload();
    final cost = await requests(a.sync);
    expect(server.doses.table.rows, hasLength(730));
    expect(cost.singleReads, lessThanOrEqualTo(3), reason: 'the three parents');
    expect(cost.all, lessThanOrEqualTo(40));
    await b.sync();
    expect(await b.count('1 = 1'), 730);
    await expectSettled([a, b]);
  });

  test('upgrade day: each device repairs, sweeps what the server still '
      'holds pending, and the second writes nothing', () async {
    a.online = false;
    await createYear(a);
    a.online = true;
    await a.sync();
    a.service.dispose();
    await AppDatabase.instance.reset();
    // As 0.3.0 left it: the server rows carry no v2 bookkeeping and the
    // past doses are pending there; each device holds them synced with no
    // base, the past ones marked missed by its own sweep.
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      for (final row in server.core.rowsOf(table).values) {
        row
          ..['sync_xid'] = 0
          ..['row_version'] = 1
          ..['write_id'] = null
          ..['edited_at'] = null
          ..['field_edited_at'] = <String, Object?>{};
      }
    }
    final c = _Device(
      'C',
      '${dir.path}/c.db',
      server,
      cursors: _UpgradedCursors(),
    );
    final d = _Device(
      'D',
      '${dir.path}/d.db',
      server,
      cursors: _UpgradedCursors(),
    );
    for (final device in [c, d]) {
      File(a.path).copySync(device.path);
      await device.run((db) async {
        for (final t in [
          'medications',
          'treatments',
          'prescriptions',
          'dose_logs',
        ]) {
          await db.update(t, {
            'sync_version': null,
            'sync_base': null,
            'sync_write_id': null,
            'field_edited_at': null,
            'edited_at': null,
            'sync_status': SyncStatus.synced,
          });
        }
        await db.update(
          'dose_logs',
          {'status': 'missed'},
          where: "status = 'pending' AND scheduled_time < ?",
          whereArgs: [DateTime.now().toIso8601String()],
        );
      });
    }
    final overdue = await c.count("status = 'missed'");
    expect(overdue, greaterThan(300));
    final repairs = await requests(() async {
      await c.sync();
      await d.sync();
    });
    expect(repairs.writes, 0);
    expect(repairs.singleReads, 0);
    final onC = await requests(c.sweep);
    expect(onC.writes, (overdue / 100).ceil());
    expect(onC.singleReads, 0);
    final before = versions();
    final onD = await requests(d.sweep);
    expect(versions(), before, reason: 'the second device writes nothing');
    expect(onD.singleReads, 0);
    expect(onD.all, lessThanOrEqualTo(2 * (overdue / 100).ceil() + 10));
    for (final device in [c, d]) {
      expect(await device.count("status = 'missed'"), overdue);
    }
    await expectSettled([c, d]);
    c.service.dispose();
    d.service.dispose();
  });
}
