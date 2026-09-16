/// Two devices on one account, one server: a schedule made or changed on one
/// device must produce the same doses, and the same reminders, on the other.
///
/// Generated doses carry the 1970 stamp, so a device whose dose cursor has
/// seen any real change never pulls them: each device generates its own
/// copies, which only works if both devices derive the same ids and times
/// from the prescription they hold. Every test therefore starts from a
/// realistic state, with both dose cursors past a real, server-stamped
/// change ([_Harness.warmUp]).
///
/// The fake server stores `start_time` as a `timestamptz` column in a UTC
/// session does (see `FakePrescriptionRemote.asTimestamptz`). The DST cases
/// only bite in a zone with daylight saving time (the suite normally runs in
/// Europe/Rome); elsewhere they pass trivially.
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
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class _Server {
  DateTime now() => DateTime.now().toUtc();
  late final meds = FakeMedicationRemote(now);
  late final treatments = FakeTreatmentRemote(now);
  late final prescriptions = FakePrescriptionRemote(now);
  late final doses = FakeDoseLogRemote(now);
  late final families = FakeFamilyRemote(now);

  Iterable<Map<String, dynamic>> dosesOf(String prescriptionId) => doses
      .table
      .rows
      .values
      .where((r) => r['prescription_id'] == prescriptionId);
}

class _Device {
  _Device(this.name, this.path, this.server) {
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
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: doseLogLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
    );
  }

  final String name;
  final String path;
  final _Server server;
  bool online = true;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  final prescriptionLocal = PrescriptionLocalDatasource();
  final doseLogLocal = DoseLogLocalDatasource();
  late final SyncService service;
  late final DoseLogRepositoryImpl doses;
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
    _requests.add(cycle);
    return cycle;
  }

  /// Opens this device's database, runs [body], and waits for every sync
  /// the body asked for before the database is handed to the other device.
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
    // Keep every later stamp strictly after this step's.
    await Future<void>.delayed(const Duration(milliseconds: 3));
    return result;
  }

  Future<void> sync() => run((_) async => service.syncAll());

  /// This device's live doses of [prescriptionId], as `id@local time`.
  Future<Set<String>> slots(String prescriptionId) => run((db) async {
    final rows = await doseLogLocal.getDoseLogsByPrescription(prescriptionId);
    return {for (final d in rows) '${d.id}@${d.scheduledTime}'};
  });

  Future<Map<String, dynamic>> row(String table, String id) => run(
    (db) async =>
        (await db.query(table, where: 'id = ?', whereArgs: [id])).single,
  );
}

class _Harness {
  _Harness(this.dir) {
    a = _Device('A', '${dir.path}/a.db', server);
    b = _Device('B', '${dir.path}/b.db', server);
  }

  final Directory dir;
  final server = _Server();
  late final _Device a;
  late final _Device b;

  /// A creates a prescription on its own device, pushes it and generates its
  /// schedule, as the prescription sheet does.
  Future<SeededPrescription> createOnA({
    required DateTime start,
    int durationDays = 1,
    int intervalHours = 8,
    String scheduleType = 'fixed_interval',
    String? times,
  }) async {
    late SeededPrescription seeded;
    await a.run((db) async {
      seeded = await seedPrescription(
        db,
        startTime: start,
        durationDays: durationDays,
        intervalHours: intervalHours,
        scheduleType: scheduleType,
      );
      await db.update(
        'prescriptions',
        {'schedule_times': ?times, 'sync_status': SyncStatus.pendingCreate},
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
      // The sheet saves the prescription and generates its schedule at
      // once; the sync both of them ask for runs afterwards.
      await a.doses.generateDoseLogsForPrescription(seeded.prescriptionId);
      await a.service.syncAll();
    });
    return seeded;
  }

  /// Both devices pull a real, server-stamped dose change, so their dose
  /// cursors sit near now, as they do in real use.
  Future<void> warmUp() async {
    final w = await createOnA(start: DateTime(2026, 3, 1, 8));
    await b.sync();
    final id = (await a.doseLogLocal.getDoseLogsByPrescription(
      w.prescriptionId,
    )).first.id;
    await a.run((_) => a.doses.markDoseTaken(id));
    await b.sync();
    await a.sync();
    for (final device in [a, b]) {
      final cursor = await device.cursors.lastPullAt('dose_logs');
      expect(cursor!.year, greaterThan(2000), reason: device.name);
    }
  }
}

void main() {
  late Directory dir;
  late _Harness h;

  setUp(() async {
    await setUpTestDatabase();
    dir = Directory.systemTemp.createTempSync('medora_schedule_');
    h = _Harness(dir);
    await h.warmUp();
  });

  tearDown(() async {
    h.a.service.dispose();
    h.b.service.dispose();
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  group('the same schedule gives the same doses on every device', () {
    Future<void> expectSameSlots({
      required DateTime start,
      required int durationDays,
      String scheduleType = 'fixed_interval',
      String? times,
    }) async {
      final p = await h.createOnA(
        start: start,
        durationDays: durationDays,
        scheduleType: scheduleType,
        times: times,
      );
      final onA = await h.a.slots(p.prescriptionId);
      expect(onA, isNotEmpty);
      if (scheduleType == 'fixed_interval') {
        expect(onA.first, endsWith('@$start'));
      }
      await h.b.sync();
      await h.b.run(
        (_) => h.b.doses.generateDoseLogsForPrescription(p.prescriptionId),
      );
      expect(await h.b.slots(p.prescriptionId), onA, reason: 'B');
      // A pulls its own prescription back (the server's copy) and
      // generates again: nothing new.
      await h.a.run((db) async {
        await h.a.cursors.clear();
        await h.a.service.syncAll();
        await h.a.doses.generateDoseLogsForPrescription(p.prescriptionId);
      });
      expect(await h.a.slots(p.prescriptionId), onA, reason: 'A');
      await h.a.sync();
      await h.b.sync();
      expect(h.server.dosesOf(p.prescriptionId), hasLength(onA.length));
    }

    test('every eight hours', () async {
      await expectSameSlots(start: DateTime(2026, 3, 10, 8), durationDays: 2);
    });

    test('every eight hours across a daylight saving change', () async {
      await expectSameSlots(start: DateTime(2026, 10, 23, 8), durationDays: 4);
    });

    test('at set times of day across a daylight saving change', () async {
      await expectSameSlots(
        start: DateTime(2026, 3, 27, 7),
        durationDays: 4,
        scheduleType: 'times_per_day',
        times: '["08:00","20:00"]',
      );
    });

    test('a pulled prescription keeps the start time the user chose', () async {
      final start = DateTime(2026, 3, 10, 8, 30);
      final p = await h.createOnA(start: start);
      await h.b.sync();
      final row = await h.b.row('prescriptions', p.prescriptionId);
      final pulled = await h.b.run(
        (_) => h.b.prescriptionLocal.getPrescriptionById(p.prescriptionId),
      );
      expect(pulled!.startTime, start, reason: '${row['start_time']}');
      expect(pulled.startTime.isUtc, isFalse);
    });
  });
}
