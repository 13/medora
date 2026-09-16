/// Two devices on one account, one server: a dose taken on one device must
/// end up "taken" on every device, whatever the other device does
/// automatically (marking overdue doses missed, generating or regenerating
/// the schedule) and in whichever order the two devices sync.
///
/// Each device has its own SQLite file, sync service, cursors and backoff
/// store; they share the fake server, whose clock stamps every update as the
/// `update_updated_at` trigger does. Only one device's database is open at a
/// time ([_Device.run]).
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
import 'package:medora/services/app_startup_tasks.dart';
import 'package:medora/services/dose_maintenance_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

/// The shared server.
class _Server {
  DateTime now() => DateTime.now().toUtc();
  late final meds = FakeMedicationRemote(now);
  late final treatments = FakeTreatmentRemote(now);
  late final prescriptions = FakePrescriptionRemote(now);
  late final doses = FakeDoseLogRemote(now);
  late final families = FakeFamilyRemote(now);

  Map<String, dynamic> dose(String id) => doses.table.rows[id]!;
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
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: doseLogLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
    );
    // The app's startup: maintenance marks doses overdue for more than the
    // default grace period missed, and the startup sync runs.
    startup = AppStartupTasks(
      maintenance: () => DoseMaintenanceService(
        doses: doses,
      ).markOverdueAsMissed(grace: const Duration(minutes: 120)),
      reminders: () async {},
      sync: () async => service.syncAll(),
      syncDelay: Duration.zero,
      minSyncInterval: Duration.zero,
    );
  }

  final String name;
  final String path;
  final _Server server;
  bool online = true;
  final cursors = SyncCursorStore.inMemory();
  final prescriptionLocal = PrescriptionLocalDatasource();
  final doseLogLocal = DoseLogLocalDatasource();
  late final SyncService service;
  late final DoseLogRepositoryImpl doses;
  late final AppStartupTasks startup;
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

  Future<Map<String, dynamic>> dose(String id) => run(
    (db) async =>
        (await db.query('dose_logs', where: 'id = ?', whereArgs: [id])).single,
  );
}

/// The 08:00 dose of a one-day, every-eight-hours prescription, long past.
final _first = DateTime(2026, 3, 1, 8);

void main() {
  late Directory dir;
  late _Server server;
  late _Device a;
  late _Device b;
  late SeededPrescription seeded;
  late String doseId;

  setUp(() async {
    await setUpTestDatabase();
    dir = Directory.systemTemp.createTempSync('medora_devices_');
    server = _Server();
    a = _Device('A', '${dir.path}/a.db', server);
    b = _Device('B', '${dir.path}/b.db', server);

    // A creates the prescription and its schedule; both reach the server.
    await a.run((db) async {
      seeded = await seedPrescription(db, durationDays: 1);
      for (final table in ['medications', 'treatments', 'prescriptions']) {
        await db.update(table, {'sync_status': SyncStatus.pendingCreate});
      }
      await a.service.syncAll();
      final generated = await a.doses.generateDoseLogsForPrescription(
        seeded.prescriptionId,
      );
      doseId = generated.dataOrNull!
          .firstWhere((d) => d.scheduledTime == _first)
          .id;
    });
    // B signs in and pulls everything.
    await b.sync();
    expect(server.dose(doseId)['status'], 'pending');
    expect((await b.dose(doseId))['status'], 'pending');
  });

  tearDown(() async {
    a.service.dispose();
    b.service.dispose();
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  Future<void> expectTakenEverywhere() async {
    // Both devices sync once more, in either order, and must agree.
    await a.sync();
    await b.sync();
    await a.sync();
    expect(server.dose(doseId)['status'], 'taken', reason: 'server');
    for (final device in [a, b]) {
      final row = await device.dose(doseId);
      expect(row['status'], 'taken', reason: device.name);
      expect(row['taken_time'], isNotNull, reason: device.name);
      expect(row['sync_status'], SyncStatus.synced, reason: device.name);
    }
  }

  group('marking overdue doses missed', () {
    test('A takes the dose and syncs; B starts up stale', () async {
      await a.run((_) => a.doses.markDoseTaken(doseId));
      expect(server.dose(doseId)['status'], 'taken');

      await b.run((_) => b.startup.run());

      expect(server.dose(doseId)['status'], 'taken');
      await expectTakenEverywhere();
    });

    test('A takes the dose offline; B starts up and syncs first', () async {
      a.online = false;
      await a.run((_) => a.doses.markDoseTaken(doseId));
      expect(server.dose(doseId)['status'], 'pending');

      await b.run((_) => b.startup.run());
      expect((await b.dose(doseId))['status'], 'missed');

      a.online = true;
      await expectTakenEverywhere();
    });

    test('B starts up offline, then both sync in either order', () async {
      b.online = false;
      await b.run((_) => b.startup.run());
      expect((await b.dose(doseId))['status'], 'missed');

      await a.run((_) => a.doses.markDoseTaken(doseId));
      b.online = true;
      await b.run((_) => b.startup.run());
      await expectTakenEverywhere();
    });

    test('A takes the dose after B marked it missed and synced', () async {
      await b.run((_) => b.startup.run());
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await expectTakenEverywhere();
    });

    test('pulling the pending copy again does not undo "missed"', () async {
      await b.run((_) => b.startup.run());
      // A full pull returns the server's pending copy the conclusion was
      // drawn from (a stale skip rewinds the cursor the same way).
      await b.cursors.clear();
      await b.sync();
      final row = await b.dose(doseId);
      expect(row['status'], 'missed');
      expect(row['sync_status'], SyncStatus.synced);
      expect(server.dose(doseId)['status'], 'pending');

      // A real change on the server still wins.
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await expectTakenEverywhere();
    });

    test('an undo still waiting to be pushed is not marked missed', () async {
      await a.run((_) => a.doses.markDoseTaken(doseId));
      a.online = false;
      await a.run((_) => a.doses.markDosePending(doseId));
      // Past the grace period, still offline.
      await a.run((_) => a.startup.run());
      final offline = await a.dose(doseId);
      expect(offline['status'], 'pending');
      expect(offline['sync_status'], SyncStatus.pendingUpdate);

      // The undo reaches the server as what the user did.
      a.online = true;
      await a.run((_) => a.startup.run());
      expect(server.dose(doseId)['status'], 'pending');
      // Once it is synced, the next start draws the local conclusion.
      await a.run((_) => a.startup.run());
      final after = await a.dose(doseId);
      expect(after['status'], 'missed');
      expect(after['sync_status'], SyncStatus.synced);
      expect(server.dose(doseId)['status'], 'pending');
    });

    test('startup marks doses missed only after its sync', () async {
      await a.run((_) => a.doses.markDoseTaken(doseId));
      final calls = <String>[];
      final tasks = AppStartupTasks(
        maintenance: () async {
          calls.add('maintenance');
          await b.doses.markOverduePendingAsMissed(DateTime.now());
        },
        reminders: () async => calls.add('reminders'),
        sync: () async {
          calls.add('sync');
          await b.service.syncAll();
        },
        syncDelay: Duration.zero,
        minSyncInterval: Duration.zero,
      );
      // The sync pulls A's "taken" before anything is marked missed, so B
      // never shows the dose as missed, not even locally.
      await b.run((_) => tasks.run());
      expect(calls, ['sync', 'maintenance', 'reminders']);
      final row = await b.dose(doseId);
      expect(row['status'], 'taken');
      expect(row['sync_status'], SyncStatus.synced);
    });
  });

  group('generating doses', () {
    test('B generates a dose the server already has as taken', () async {
      await a.run((_) => a.doses.markDoseTaken(doseId));
      // B lost its dose logs (a failed pull, a row behind its cursor).
      await b.run((db) async {
        await db.delete('dose_logs');
        await b.doses.generateDoseLogsForPrescription(seeded.prescriptionId);
      });
      expect(server.dose(doseId)['status'], 'taken');
      await expectTakenEverywhere();
    });

    test('B generates offline, A takes the dose, then B syncs', () async {
      b.online = false;
      await b.run((db) async {
        await db.delete('dose_logs');
        await b.doses.generateDoseLogsForPrescription(seeded.prescriptionId);
      });
      // B's copy is overdue too: it is marked missed before B is online.
      await b.run((_) => b.startup.run());
      await a.run((_) => a.doses.markDoseTaken(doseId));
      b.online = true;
      await b.sync();
      expect(server.dose(doseId)['status'], 'taken');
      await expectTakenEverywhere();
    });

    test('B generates offline, syncs first, then A takes the dose', () async {
      b.online = false;
      await b.run((db) async {
        await db.delete('dose_logs');
        await b.doses.generateDoseLogsForPrescription(seeded.prescriptionId);
      });
      b.online = true;
      await b.run((_) => b.startup.run());
      a.online = false;
      await a.run((_) => a.doses.markDoseTaken(doseId));
      a.online = true;
      await expectTakenEverywhere();
    });

    test('A regenerates after an edit while its copy is stale', () async {
      // B takes the dose; A has not synced since.
      await b.run((_) => b.doses.markDoseTaken(doseId));
      expect(server.dose(doseId)['status'], 'taken');
      // A extends the prescription, which regenerates its doses. The 08:00
      // dose keeps its time, and so its id.
      a.online = false;
      await a.run((db) async {
        await db.update(
          'prescriptions',
          {'duration_days': 3},
          where: 'id = ?',
          whereArgs: [seeded.prescriptionId],
        );
        await a.doses.regenerateDoseLogsForPrescription(seeded.prescriptionId);
      });
      a.online = true;
      await a.sync();
      expect(server.dose(doseId)['status'], 'taken');
      await expectTakenEverywhere();
      // The extension reached the server as new doses.
      expect(
        server.doses.table.rows.values.where(
          (r) => r['prescription_id'] == seeded.prescriptionId,
        ),
        hasLength(9),
      );
    });

    test('a pending dose regenerated with the same time is kept', () async {
      // A had undone a take locally: the undo is still waiting to be pushed.
      a.online = false;
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await a.run((_) => a.doses.markDosePending(doseId));
      final before = await a.dose(doseId);
      await a.run((db) async {
        await db.update(
          'prescriptions',
          {'duration_days': 3},
          where: 'id = ?',
          whereArgs: [seeded.prescriptionId],
        );
        await a.doses.regenerateDoseLogsForPrescription(seeded.prescriptionId);
      });
      final after = await a.dose(doseId);
      expect(after['sync_status'], SyncStatus.pendingUpdate);
      expect(after['updated_at'], before['updated_at']);
    });
  });

  // The server stamps every update with its own clock, so of two explicit
  // changes the one that reaches the server last wins, whenever it was
  // made.
  group('an explicit status wins in the order the devices sync', () {
    test('B skips the dose after A took it', () async {
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await b.sync();
      await b.run((_) => b.doses.markDoseSkipped(doseId));
      await a.sync();
      expect(server.dose(doseId)['status'], 'skipped');
      expect((await a.dose(doseId))['status'], 'skipped');
      expect((await b.dose(doseId))['status'], 'skipped');
    });

    test('B marks the dose missed after A took it offline', () async {
      a.online = false;
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await b.run((_) => b.doses.markDoseMissed(doseId));
      a.online = true;
      await a.sync();
      await b.sync();
      expect(server.dose(doseId)['status'], 'missed');
      final onA = await a.dose(doseId);
      expect(onA['status'], 'missed');
      expect(onA['sync_status'], SyncStatus.synced);
      expect((await b.dose(doseId))['status'], 'missed');
    });

    test('A takes the dose after B explicitly marked it missed', () async {
      await b.run((_) => b.doses.markDoseMissed(doseId));
      await a.sync();
      await a.run((_) => a.doses.markDoseTaken(doseId));
      await expectTakenEverywhere();
    });
  });
}
