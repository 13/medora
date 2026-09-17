/// Two devices on one account and one fake server (sync v2).
///
/// Each device has its own SQLite file, sync service, cursors, failure
/// store and repositories; they share the server and one clock. Only one
/// device's database is open at a time ([Device.run]). Every sync a
/// repository asks for runs before [Device.run] returns, as the app's
/// queued cycles do.
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
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_remotes.dart';

export 'fake_remotes.dart';

class Device {
  Device(this.name, this.path, this.server, {required DateTime Function() now})
    : _now = now {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(now: now),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(now: now),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(now: now),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(now: now),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      newWriteId: () => '$name-w${_ids++}',
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
      now: now,
    );
    medications = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(now: now),
      requestSync: _requestSync,
      now: now,
      newOpId: () => '$name-op${_ids++}',
    );
    treatments = TreatmentRepositoryImpl(
      localDatasource: TreatmentLocalDatasource(now: now),
      requestSync: _requestSync,
      now: now,
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: DoseLogLocalDatasource(now: now),
      prescriptionLocal: PrescriptionLocalDatasource(now: now),
      requestSync: _requestSync,
      now: now,
    );
  }

  final String name;
  final String path;
  final FakeServer server;
  final DateTime Function() _now;
  bool online = true;
  var _ids = 0;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  late final SyncService service;
  late final MedicationRepositoryImpl medications;
  late final TreatmentRepositoryImpl treatments;
  late final DoseLogRepositoryImpl doses;
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
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
    return result;
  }

  Future<SyncReport?> sync() => run((_) => service.syncAll());

  /// This device's copy of the row [id] of [table]; throws a [StateError]
  /// when it holds none.
  Future<Map<String, Object?>> row(String table, String id) => run(
    (db) async =>
        (await db.query(table, where: 'id = ?', whereArgs: [id])).single,
  );

  DateTime now() => _now();
}

class TwoDevices {
  /// [transport]: how both devices reach the server; the app's real
  /// PostgREST datasources in [FakeTransport.http].
  TwoDevices({this.transport = FakeTransport.dart}) {
    dir = Directory.systemTemp.createTempSync('medora_two_');
    server = FakeServer(() => clock, transport: transport);
    a = Device('A', '${dir.path}/a.db', server, now: () => clock);
    b = Device('B', '${dir.path}/b.db', server, now: () => clock);
  }

  final FakeTransport transport;

  /// The server's tables.
  FakeServerCore get core => server.core;

  /// The next stock change lands and its answer is lost.
  void loseNextStockAnswer() => server.meds.stock.loseNextAnswers++;

  /// The one clock both devices and the server read; tests move it.
  DateTime clock = DateTime.utc(2026, 3, 5, 8);
  late final Directory dir;
  late final FakeServer server;
  late final Device a;
  late final Device b;

  void advance(Duration d) => clock = clock.add(d);

  Future<void> dispose() async {
    a.service.dispose();
    b.service.dispose();
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = null;
    dir.deleteSync(recursive: true);
  }
}
