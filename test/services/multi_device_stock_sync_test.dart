/// Two phones on one account, one server: every stock change made on either
/// phone counts once, whatever the order the phones sync in, and whatever
/// answers get lost on the way.
///
/// Each phone has its own SQLite file, repositories, sync service, cursors
/// and backoff store; only one phone's database is open at a time
/// ([_Phone.run]). They start from a realistic state: a medication made on
/// A three days ago, one tablet already taken and synced, pulled by B.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/services/backup_service.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 3, 2, 9);
  void advance(Duration d) => now = now.add(d);
}

class _Phone {
  _Phone(this.name, this.path, this.server, this.clock) {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
      now: () => clock.now,
    );
    var n = 0;
    medications = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(now: () => clock.now),
      requestSync: _requestSync,
      now: () => clock.now,
      newOpId: () => '$name-op${n++}',
    );
  }

  final String name;
  final String path;
  final FakeServer server;
  final _Clock clock;
  bool online = true;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  late final SyncService service;
  late final MedicationRepositoryImpl medications;
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
    _requests.add(cycle);
    return cycle;
  }

  /// Opens this phone's database, runs [body], and waits for every sync the
  /// body asked for before the database is handed to the other phone.
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
    clock.advance(const Duration(seconds: 1));
    return result;
  }

  Future<SyncReport?> sync() => run((_) => service.syncAll());

  /// A sync after every backoff has run out.
  Future<SyncReport?> syncLater() {
    clock.advance(const Duration(hours: 7));
    return sync();
  }

  Future<void> take(String id, [int count = 1]) =>
      run((_) => medications.updateQuantity(id, -count));

  Future<int> quantity(String id) => run(
    (db) async =>
        (await db.query(
              'medications',
              where: 'id = ?',
              whereArgs: [id],
            )).single['quantity']!
            as int,
  );

  Future<Map<String, Object?>?> row(String id) => run((db) async {
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.single;
  });

  Future<List<String>> waiting() => run(
    (_) async => [
      for (final op in await StockOutboxLocalDatasource().pending()) op.opId,
    ],
  );
}

const _med = 'med-ibu';

void main() {
  late Directory dir;
  late _Clock clock;
  late FakeServer server;
  late _Phone a;
  late _Phone b;

  Map<String, dynamic> serverRow([String id = _med]) =>
      server.meds.table.rows[id]!;
  int serverQuantity([String id = _med]) => serverRow(id)['quantity'] as int;

  /// Both phones sync until nothing moves, and must agree with the server.
  Future<void> expectSettled(int quantity, {String id = _med}) async {
    for (final phone in [a, b, a, b]) {
      final report = (await phone.syncLater())!;
      expect(report.failures, isEmpty, reason: phone.name);
    }
    final versions = serverRow(id)['row_version'];
    for (final phone in [a, b]) {
      await phone.syncLater();
    }
    expect(serverRow(id)['row_version'], versions, reason: 'nothing loops');
    expect(serverQuantity(id), quantity, reason: 'server');
    for (final phone in [a, b]) {
      expect(await phone.quantity(id), quantity, reason: phone.name);
      expect(await phone.waiting(), isEmpty, reason: phone.name);
      expect(
        (await phone.row(id))!['sync_status'],
        SyncStatus.synced,
        reason: phone.name,
      );
    }
  }

  setUp(() async {
    await setUpTestDatabase();
    dir = Directory.systemTemp.createTempSync('medora_stock_phones_');
    clock = _Clock();
    server = FakeServer(() => clock.now);
    a = _Phone('A', '${dir.path}/a.db', server, clock);
    b = _Phone('B', '${dir.path}/b.db', server, clock);

    // Three days ago: A adds the pack (30 tablets) and takes one.
    await a.run(
      (_) => a.medications.addMedication(
        const Medication(
          id: _med,
          name: 'Ibuprofen',
          quantity: 30,
          quantityUnit: 'tablets',
        ),
      ),
    );
    await a.take(_med);
    clock.now = DateTime.utc(2026, 3, 5, 8);
    // B signs in and pulls it.
    await b.sync();
    await a.sync();
    expect(serverQuantity(), 29);
    expect(server.core.ledger.keys, ['A-op0']);
    expect(await b.quantity(_med), 29);
    expect(await a.waiting(), isEmpty);
  });

  tearDown(() async {
    a.service.dispose();
    b.service.dispose();
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  for (final aFirst in [true, false]) {
    final order = aFirst ? 'A syncs first' : 'B syncs first';

    test('both phones take a tablet offline: both count ($order)', () async {
      a.online = false;
      b.online = false;
      await a.take(_med);
      await b.take(_med);
      expect(await a.quantity(_med), 28);
      expect(await b.quantity(_med), 28);
      a.online = true;
      b.online = true;

      await (aFirst ? a : b).sync();
      await (aFirst ? b : a).sync();

      expect(serverQuantity(), 27);
      await expectSettled(27);
    });

    test('a restock on one phone and a dose on the other ($order)', () async {
      a.online = false;
      b.online = false;
      await a.run((_) => a.medications.updateQuantity(_med, 20));
      await b.take(_med, 2);
      a.online = true;
      b.online = true;

      await (aFirst ? a : b).sync();
      await (aFirst ? b : a).sync();

      await expectSettled(47);
    });
  }

  test('a count on A and a dose on B: the dose that reaches the server after '
      'the count applies on top of it', () async {
    a.online = false;
    b.online = false;
    await a.run((_) async {
      final m = (await a.medications.getMedicationById(_med)).dataOrNull!;
      await a.medications.updateMedication(m.copyWith(quantity: 12));
    });
    await b.take(_med);
    a.online = true;
    b.online = true;

    await a.sync();
    expect(serverQuantity(), 12);
    await b.sync();

    await expectSettled(11);
  });

  test('a count on A and a dose on B: a dose that reached the server before '
      'the count is replaced by it', () async {
    a.online = false;
    b.online = false;
    await a.run((_) async {
      final m = (await a.medications.getMedicationById(_med)).dataOrNull!;
      await a.medications.updateMedication(m.copyWith(quantity: 12));
    });
    await b.take(_med);
    a.online = true;
    b.online = true;

    await b.sync();
    expect(serverQuantity(), 28);
    await a.sync();

    await expectSettled(12);
    expect(
      [
        for (final e in server.core.ledger.entries)
          (e.key, e.value.quantityAfter),
      ],
      [('A-op0', 29), ('B-op0', 28), ('A-op1', 12)],
    );
  });

  test('a lost answer and a retry: the dose counts once on every '
      'phone', () async {
    b.online = false;
    await b.take(_med);
    await b.take(_med);
    b.online = true;
    server.meds.stock.loseNextAnswers = 1;

    final first = (await b.sync())!;
    expect(first.failures.map((f) => f.id), ['B-op0']);
    expect(serverQuantity(), 28);
    // What B shows meanwhile: the server's 28 (which holds its first dose)
    // and the second on top.
    expect(await b.quantity(_med), 27);
    await a.sync();
    expect(await a.quantity(_med), 28);

    final retry = (await b.syncLater())!;
    expect(retry.failures, isEmpty);
    expect(server.core.ledger.keys, ['A-op0', 'B-op0', 'B-op1']);
    await expectSettled(27);
  });

  test('a medication deleted on A while B takes a dose offline', () async {
    b.online = false;
    await b.take(_med);
    b.online = true;
    await a.run((_) => a.medications.deleteMedication(_med));
    expect(serverRow()['deleted_at'], isNotNull);

    final report = (await b.sync())!;

    expect(report.failures, isEmpty);
    expect(await b.row(_med), isNull);
    expect(await b.waiting(), isEmpty);
    expect(server.core.ledger.keys, ['A-op0']);
    expect(await a.row(_med), isNull);
  });

  test('"delete all data" on A while B holds a dose not sent yet', () async {
    b.online = false;
    await b.take(_med);
    b.online = true;
    // What the settings dialog does: the server rows go, then this phone's.
    server.meds.table.hardDelete(_med);
    await a.run((_) => AppDatabase.instance.clearAllData());

    final report = (await b.sync())!;

    expect(report.failures, isEmpty);
    expect(await b.waiting(), isEmpty);
    expect(server.core.ledger, isEmpty);
    expect(server.meds.table.rows[_med], isNull);
    expect(await a.waiting(), isEmpty);
    // Known limit (before this task too): B keeps its synced copy, since a
    // row removed from the server leaves no tombstone to pull.
    expect(await b.quantity(_med), 28);
  });

  test('a medication added offline and restocked before its first sync goes '
      'out once with its quantity', () async {
    const id = 'med-new';
    b.online = false;
    await b.run(
      (_) => b.medications.addMedication(
        const Medication(id: id, name: 'Moment', quantity: 5),
      ),
    );
    await b.run((_) => b.medications.updateQuantity(id, 10));
    await b.take(id);
    expect(await b.quantity(id), 14);
    b.online = true;

    await b.sync();

    expect(serverQuantity(id), 14);
    expect(server.core.ledger.keys, ['A-op0']);
    await expectSettled(14, id: id);
  });

  test('a medication added offline whose insert answer is lost goes out '
      'once', () async {
    const id = 'med-new';
    b.online = false;
    await b.run(
      (_) => b.medications.addMedication(
        const Medication(id: id, name: 'Moment', quantity: 5),
      ),
    );
    await b.run((_) => b.medications.updateQuantity(id, 10));
    b.online = true;
    server.meds.table.loseAnswerFor.add(id);

    final first = (await b.sync())!;
    expect(first.failures.map((f) => f.id), [id]);
    expect(serverQuantity(id), 15);
    // Taken while the answer is unknown.
    await b.take(id);

    await b.syncLater();
    expect(serverQuantity(id), 14);
    await expectSettled(14, id: id);
  });

  test('an undone dose on B, with the answer to the dose lost: back where it '
      'was on both phones', () async {
    // An as-needed dose logged and undone: a change, then its reverse. The
    // dose's own sync loses its answer.
    server.meds.stock.loseNextAnswers = 1;
    await b.take(_med);
    expect(serverQuantity(), 28);
    expect(await b.waiting(), ['B-op0']);
    await b.run((_) => b.medications.updateQuantity(_med, 1));
    expect(await b.quantity(_med), 29);

    await b.syncLater();

    expect(server.core.ledger.keys, ['A-op0', 'B-op0', 'B-op1']);
    await expectSettled(29);
  });

  test('a phone that left cloud mode keeps its doses for its return', () async {
    // B turns cloud off and keeps its data: its repository no longer asks
    // for syncs.
    final local = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(now: () => clock.now),
      now: () => clock.now,
      newOpId: () => 'B-local',
    );
    await b.run((_) => local.updateQuantity(_med, -3));
    await a.take(_med);
    await a.sync();
    expect(serverQuantity(), 28);

    // B signs back in to the same account.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await b.run((_) async {
      final marker = LocalUploadMarker(
        database: AppDatabase.instance,
        cursors: b.cursors,
        prefs: prefs,
      );
      await marker.setOwner('user-a');
      await marker.markAllForUpload('user-a');
    });
    await b.sync();

    expect(serverQuantity(), 25);
    await expectSettled(25);
  });

  test('a cloud restore on B counts the restored quantity, and a dose from A '
      'that arrives later applies on top', () async {
    final photos = Directory('${dir.path}/photos')..createSync();
    BackupService backup() => BackupService(
      database: AppDatabase.instance,
      photos: PhotoStorage(rootDirectory: () async => photos),
      now: () => clock.now,
      appVersion: '0.4.0+19',
      newOpId: () => 'B-restore',
    );
    // A backup B made when it held 40 (before a later count).
    await b.run((db) => db.update('medications', {'quantity': 40}));
    final file = await b.run((_) => backup().exportToFile(dir));
    await b.run((db) => db.update('medications', {'quantity': 29}));
    a.online = false;
    await a.take(_med);
    a.online = true;

    await b.run(
      (_) =>
          backup().restore(file, mode: RestoreMode.replace, markPending: true),
    );
    await b.sync();
    expect(serverQuantity(), 40);
    await a.sync();

    await expectSettled(39);
  });

  group('a 0.3.0 phone in the fleet', () {
    /// What 0.3.0 sends for a stock change: the whole row, with the
    /// absolute quantity it computed from the copy it last pulled.
    Future<void> legacyWrite(Map<String, dynamic> pulled, int quantity) =>
        server.meds.table.upsert({
          ...MedicationModel.fromJson(pulled).toJson(),
          'quantity': quantity,
          'updated_at': clock.now.toIso8601String(),
        });

    test('its absolute quantity replaces the changes the server applied since '
        'its last pull, and 0.4.0 phones take the server\'s', () async {
      // C (0.3.0) pulled the row at 29.
      final pulledByC = Map<String, dynamic>.of(serverRow());
      // A takes one and syncs: 28.
      await a.take(_med);
      await a.sync();
      expect(serverQuantity(), 28);
      // B takes one offline.
      b.online = false;
      await b.take(_med);
      b.online = true;
      // C takes two, and sends 29 - 2 = 27: A's dose is lost (the right
      // count would be 26).
      await legacyWrite(pulledByC, 27);
      expect(serverQuantity(), 27);

      // B's change still applies on top of what the server holds: 26, where
      // counting every dose would give 25.
      await b.sync();
      expect(serverQuantity(), 26);
      await expectSettled(26);
    });

    test('a 0.4.0 change that reaches the server after the 0.3.0 write '
        'applies on top of it', () async {
      final pulledByC = Map<String, dynamic>.of(serverRow());
      a.online = false;
      await a.take(_med, 2);
      a.online = true;
      await legacyWrite(pulledByC, 25);

      await a.sync();

      expect(serverQuantity(), 23);
      await expectSettled(23);
    });

    test('a 0.3.0 rename sends the quantity it last pulled too', () async {
      final pulledByC = Map<String, dynamic>.of(serverRow());
      await a.take(_med, 4);
      await a.sync();
      expect(serverQuantity(), 25);
      await server.meds.table.upsert({
        ...MedicationModel.fromJson(pulledByC).toJson(),
        'name': 'Ibuprofen 400',
        'updated_at': clock.now.toIso8601String(),
      });

      await expectSettled(29);
      expect(serverRow()['name'], 'Ibuprofen 400');
      expect((await a.row(_med))!['name'], 'Ibuprofen 400');
    });
  });
}
