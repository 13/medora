/// "Delete all data" on one phone reaches the account's other phones
/// (design section 7.9).
///
/// Two 0.4.0 phones on one account, one server, one clock. They start from
/// a realistic state: three days ago A made a medication, an illness and a
/// schedule, took a dose, and B pulled all of it. Each case then deletes
/// everything on A the way the settings dialog does (the server function,
/// then this phone's own wipe), and checks what B and the server hold.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/sync/remote_wipe.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_reminder_port.dart';
import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 3, 2, 9);
  void advance(Duration d) => now = now.add(d);
}

/// A notification port that knows which dose reminders are still booked.
class _LivePort extends FakePort {
  final live = <String>{};

  @override
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {
    await super.scheduleForDose(dose: dose, medicationName: medicationName);
    live.add(dose.id);
  }

  @override
  Future<void> cancelForDose(String doseId) async {
    await super.cancelForDose(doseId);
    live.remove(doseId);
  }

  @override
  Future<void> cancelAllDoses() async {
    await super.cancelAllDoses();
    live.clear();
  }
}

class _Phone {
  _Phone(
    this.name,
    this.path,
    this.server,
    this.clock, {
    SyncCursorStore? cursors,
  }) : cursors = cursors ?? SyncCursorStore.inMemory() {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(now: () => clock.now),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(now: () => clock.now),
      treatmentRemote: server.treatments,
      prescriptionLocal: prescriptionLocal,
      prescriptionRemote: server.prescriptions,
      doseLogLocal: doseLocal,
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: this.cursors,
      failures: failures,
      now: () => clock.now,
      capRetryDelay: const Duration(days: 1),
      onRemoteWipe: (removed) async => wipes.add(removed),
    );
    var n = 0;
    medications = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(now: () => clock.now),
      requestSync: _requestSync,
      now: () => clock.now,
      newOpId: () => '$name-op${n++}',
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: doseLocal,
      prescriptionLocal: prescriptionLocal,
      requestSync: _requestSync,
      now: () => clock.now,
    );
    reminders = ReminderScheduler(
      port: port,
      doses: doses,
      remindersEnabled: () => true,
      now: () => clock.now.toLocal(),
    );
  }

  final String name;
  final String path;
  final FakeServer server;
  final _Clock clock;
  bool online = true;
  final SyncCursorStore cursors;
  final failures = SyncFailureStore.inMemory();
  late final prescriptionLocal = PrescriptionLocalDatasource(
    now: () => clock.now,
  );
  late final doseLocal = DoseLogLocalDatasource(now: () => clock.now);
  late final SyncService service;
  late final MedicationRepositoryImpl medications;
  late final DoseLogRepositoryImpl doses;
  final port = _LivePort();
  late final ReminderScheduler reminders;
  final List<RemovedData> wipes = [];
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
    _requests.add(cycle);
    return cycle;
  }

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

  /// A cycle, then what the app does after it (the reminders).
  Future<SyncReport?> sync() async {
    final report = await run((_) => service.syncAll());
    await run((_) => reminders.reconcile());
    return report;
  }

  /// "Delete all data" in the settings dialog: the server call, then this
  /// phone's own wipe.
  Future<void> deleteAllData() async {
    server.core.deleteAllData();
    await run((_) async {
      await AppDatabase.instance.clearAllData();
      await port.cancelAllDoses();
    });
  }

  Future<List<String>> ids(String table) => run(
    (db) async => [
      for (final r in await db.query(table, orderBy: 'id')) r['id']! as String,
    ],
  );

  Future<Map<String, Object?>?> row(String table, String id) => run((db) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single;
  });
}

const _med = 'med-amox';
const _treatment = 't-sinus';
const _prescription = 'p-sinus';

void main() {
  late Directory dir;
  late _Clock clock;
  late FakeServer server;
  late _Phone a;
  late _Phone b;
  late String taken;
  late String next;

  List<String> live(String table) => [
    for (final r in server.core.rowsOf(table).values)
      if (r['deleted_at'] == null) r['id']! as String,
  ]..sort();

  /// Every phone and the server hold the same rows, nothing is waiting,
  /// and another round writes nothing.
  Future<void> expectSettled(List<_Phone> phones) async {
    for (final phone in [...phones, ...phones]) {
      final report = (await phone.sync())!;
      expect(report.failures, isEmpty, reason: phone.name);
    }
    final before = server.core.requests.length;
    for (final phone in phones) {
      await phone.sync();
    }
    expect(
      server.core.requests
          .sublist(before)
          .where((r) => !r.endsWith(':page') && !r.startsWith('rpc:')),
      isEmpty,
      reason: 'a quiet round writes nothing',
    );
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      for (final phone in phones) {
        expect(
          await phone.ids(table),
          live(table),
          reason: '${phone.name} $table',
        );
      }
    }
    for (final phone in phones) {
      await phone.run((db) async {
        for (final table in [
          'medications',
          'treatments',
          'prescriptions',
          'dose_logs',
        ]) {
          expect(
            await db.query(
              table,
              where: 'sync_status != ?',
              whereArgs: [SyncStatus.synced],
            ),
            isEmpty,
            reason: '${phone.name} $table',
          );
        }
      });
    }
  }

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('medora_wipe_phones_');
    clock = _Clock();
    server = FakeServer(() => clock.now);
    a = _Phone('A', '${dir.path}/a.db', server, clock);
    b = _Phone('B', '${dir.path}/b.db', server, clock);

    // Three days ago A made the medication (with a photo), the illness and
    // a schedule for a week, and took the first dose.
    await a.run((db) async {
      await a.medications.addMedication(
        const Medication(
          id: _med,
          name: 'Amoxicillin',
          quantity: 12,
          quantityUnit: 'tablets',
          imagePath: 'amox.jpg',
        ),
      );
      final created = clock.now.toIso8601String();
      await db.insert('treatments', {
        'id': _treatment,
        'name': 'Sinusitis',
        'start_date': '2026-03-02',
        'is_active': 1,
        'created_at': created,
        'updated_at': created,
        'edited_at': created,
        'sync_status': SyncStatus.pendingCreate,
      });
      await db.insert('prescriptions', {
        'id': _prescription,
        'treatment_id': _treatment,
        'medication_id': _med,
        'dosage': '1 tablet',
        'dosage_amount': 1.0,
        'interval_hours': 12,
        'duration_days': 7,
        'start_time': DateTime(2026, 3, 2, 8).toIso8601String(),
        'schedule_type': 'fixed_interval',
        'is_active': 1,
        'created_at': created,
        'updated_at': created,
        'edited_at': created,
        'sync_status': SyncStatus.pendingCreate,
      });
      await a.doses.generateDoseLogsForPrescription(_prescription);
    });
    taken = scheduledDoseId(_prescription, DateTime(2026, 3, 2, 8));
    next = scheduledDoseId(_prescription, DateTime(2026, 3, 8, 20));
    await a.run((_) => a.doses.markDoseTaken(taken));
    clock.now = DateTime.utc(2026, 3, 5, 8);
    await b.sync();
    await a.sync();
    expect(await b.ids('dose_logs'), hasLength(14));
    expect(b.port.live, contains(next));
  });

  tearDown(() async {
    a.service.dispose();
    b.service.dispose();
    await tearDownTestDatabase();
    dir.deleteSync(recursive: true);
  });

  test('B removes everything from before the wipe, its waiting changes '
      'too, and keeps what it made after it', () async {
    // B, offline: a take, a rename, and a medication added before the wipe.
    b.online = false;
    await b.run((_) => b.doses.markDoseTaken(next));
    await b.run((_) async {
      final med = (await b.medications.getMedicationById(_med)).dataOrNull!;
      await b.medications.updateMedication(med.copyWith(name: 'Amoxi'));
    });
    await b.run(
      (_) => b.medications.addMedication(
        const Medication(id: 'med-before', name: 'Before', quantity: 3),
      ),
    );
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    clock.advance(const Duration(hours: 1));
    // Still offline: a medication added after the wipe.
    await b.run(
      (_) => b.medications.addMedication(
        const Medication(id: 'med-after', name: 'After', quantity: 5),
      ),
    );
    b.online = true;

    final report = (await b.sync())!;

    expect(report.failures, isEmpty);
    // The medication and the one B added before, the illness, the
    // prescription and its 14 doses.
    expect(report.wiped, 18);
    expect(await b.ids('medications'), ['med-after']);
    expect(await b.ids('treatments'), isEmpty);
    expect(await b.ids('dose_logs'), isEmpty);
    expect(b.port.live, isEmpty, reason: 'no reminder is left');
    expect(b.wipes.single.photos, ['amox.jpg']);
    expect(live('medications'), ['med-after']);
    expect(server.core.rowsOf('medications').keys, ['med-after']);
    expect(server.core.rowsOf('dose_logs'), isEmpty);
    expect(server.core.ledger.keys, isEmpty);
    await expectSettled([a, b]);
    expect(a.wipes, isEmpty, reason: 'A held nothing from before');
  });

  test('B pushes changes from before the wipe in the moment after it: the '
      'server stores them deleted, and nothing comes back', () async {
    b.online = false;
    await b.run((_) async {
      final med = (await b.medications.getMedicationById(_med)).dataOrNull!;
      await b.medications.updateMedication(med.copyWith(name: 'Amoxi'));
    });
    await b.run(
      (_) => b.medications.addMedication(
        const Medication(id: 'med-before', name: 'Before', quantity: 3),
      ),
    );
    await b.run((_) => b.doses.markDoseSkipped(next));
    clock.advance(const Duration(hours: 1));
    b.online = true;
    // B has read the sync state; A deletes everything before B's first
    // request to a table.
    var wiped = false;
    server.meds.rows.beforeCall = () async {
      if (wiped) return;
      wiped = true;
      server.core.deleteAllData();
    };
    final report = (await b.sync())!;
    expect(wiped, isTrue);
    expect(report.failures, isEmpty);
    expect(live('medications'), isEmpty);
    expect(live('dose_logs'), isEmpty);
    final stale = server.core.rowsOf('medications')['med-before']!;
    expect(stale['deleted_at'], server.core.wipe!.wipedAt.toIso8601String());
    expect(
      stale['edited_at'],
      stale['deleted_at'],
      reason: 'a person\'s delete',
    );
    await a.run((_) => AppDatabase.instance.clearAllData());
    await expectSettled([a, b]);
    expect(await b.ids('medications'), isEmpty);
  });

  test('a 0.3.0 phone writes an old row back after the wipe: every 0.4.0 '
      'phone keeps it as new data', () async {
    final old = await a.row('medications', _med);
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    await b.sync();
    expect(await b.ids('medications'), isEmpty);
    clock.advance(const Duration(hours: 1));
    // The 0.3.0 phone never saw the wipe; its rename upserts the whole row.
    await server.meds.table.upsert({
      ...MedicationModel.fromLocalMap(old!).toJson(),
      'name': 'Amoxicillin 1g',
      'updated_at': clock.now.toIso8601String(),
    });
    await expectSettled([a, b]);
    expect(await a.ids('medications'), [_med]);
    expect((await b.row('medications', _med))!['name'], 'Amoxicillin 1g');
    expect(b.wipes, hasLength(1), reason: 'the wipe is applied once');
  });

  test('a phone that synced under 0.3.0 before the wipe removes its old '
      'rows on its first 0.4.0 cycle, and gets what the server has', () async {
    await b.run((_) async {});
    File(b.path).copySync('${dir.path}/u.db');
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    clock.advance(const Duration(hours: 1));
    await a.run(
      (_) => a.medications.addMedication(
        const Medication(id: 'med-new', name: 'New', quantity: 1),
      ),
    );
    SharedPreferences.setMockInitialValues({
      '${SyncCursorStore.keyPrefix}medications': '2026-03-05T08:00:00.000Z',
    });
    final prefs = await SharedPreferences.getInstance();
    final u = _Phone(
      'U',
      '${dir.path}/u.db',
      server,
      clock,
      cursors: SyncCursorStore(prefs),
    );
    addTearDown(u.service.dispose);
    await u.run((db) async {
      for (final t in [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        await db.update(t, {
          'sync_version': null,
          'sync_base': null,
          'field_edited_at': null,
        });
      }
    });

    final report = (await u.sync())!;

    expect(report.failures, isEmpty);
    expect(report.wiped, greaterThan(0));
    expect(await u.ids('medications'), ['med-new']);
    expect(await u.ids('dose_logs'), isEmpty);
    expect(await u.cursors.wipeSeen('user-a'), 1);
    await expectSettled([a, u]);
  });

  test('a phone that signs in after an old wipe uploads its own data, and '
      'removes nothing', () async {
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    clock.advance(const Duration(days: 30));
    // F kept data from before the wipe while it was signed out (a copy of
    // B's, marked for upload by the sign-in).
    await b.run((_) async {});
    File(b.path).copySync('${dir.path}/f.db');
    final f = _Phone('F', '${dir.path}/f.db', server, clock);
    addTearDown(f.service.dispose);
    await f.run((_) async {
      await LocalUploadMarker(
        database: AppDatabase.instance,
        cursors: f.cursors,
        prefs: await SharedPreferences.getInstance(),
      ).markAllForUpload('user-a');
    });

    final report = (await f.sync())!;

    expect(report.failures, isEmpty);
    expect(report.wiped, 0);
    expect(live('medications'), [_med]);
    expect(live('dose_logs'), hasLength(14));
    await expectSettled([a, f]);
    expect(await a.ids('dose_logs'), hasLength(14));
  });

  test('a force push after the wipe brings this phone\'s data back', () async {
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    clock.advance(const Duration(minutes: 5));

    final report = (await b.run((_) => b.service.forcePush()))!;

    expect(report.failures, isEmpty);
    expect(live('medications'), [_med]);
    expect(live('dose_logs'), hasLength(14));
    expect(
      server.core.rowsOf('medications')[_med]!['quantity'],
      (await b.row('medications', _med))!['quantity'],
    );
    await expectSettled([a, b]);
    expect(await a.ids('dose_logs'), hasLength(14));
    expect(b.wipes, isEmpty);
  });

  test('a server whose marker went back (a restored project) removes '
      'nothing', () async {
    server.core.wipe = (generation: 5, wipedAt: clock.now);
    await b.sync();
    expect(b.wipes, hasLength(1));
    server.core.wipe = (generation: 2, wipedAt: clock.now);
    clock.advance(const Duration(minutes: 1));
    await a.run(
      (_) => a.medications.addMedication(
        const Medication(id: 'med-a', name: 'A', quantity: 1),
      ),
    );
    final report = (await b.sync())!;
    expect(report.wiped, 0);
    // The server kept its rows (only the marker moved), so B pulled them
    // again after the first wipe, and keeps them now.
    expect(await b.ids('medications'), ['med-a', _med]);
    expect(await b.cursors.wipeSeen('user-a'), 2);
  });

  test('a phone that is wiped itself, then signs in again, removes nothing '
      'more', () async {
    clock.advance(const Duration(hours: 1));
    await a.deleteAllData();
    await a.sync();
    await a.run(
      (_) => a.medications.addMedication(
        const Medication(id: 'med-a', name: 'A', quantity: 1),
      ),
    );
    await b.sync();
    expect(await b.ids('medications'), ['med-a']);
    await expectSettled([a, b]);
    expect(a.wipes, isEmpty);
    expect(b.wipes, hasLength(1));
  });
}
