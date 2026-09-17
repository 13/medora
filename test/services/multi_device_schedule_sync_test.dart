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
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_reminder_port.dart';
import '../helpers/fake_remotes.dart';
import '../helpers/seed.dart';
import '../helpers/test_database.dart';

class _Server extends FakeServer {
  _Server() : super(() => DateTime.now().toUtc());

  Iterable<Map<String, dynamic>> dosesOf(String prescriptionId) => doses
      .table
      .rows
      .values
      .where((r) => r['prescription_id'] == prescriptionId);
}

/// A notification port that knows which dose reminders are still pending.
class _LivePort extends FakePort {
  final live = <String, DateTime>{};

  @override
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {
    await super.scheduleForDose(dose: dose, medicationName: medicationName);
    live[dose.id] = dose.scheduledTime;
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
      syncState: server.state,
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
      onPrescriptionsPulled: (pulled) async {
        if (pullHook) await schedule.applyPulled(pulled);
      },
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
    reminders = ReminderScheduler(
      port: port,
      doses: doses,
      remindersEnabled: () => true,
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
  late final DoseScheduleService schedule;
  final port = _LivePort();
  late final ReminderScheduler reminders;
  final List<Future<void>> _requests = [];

  /// Whether a pull hands its prescriptions to [schedule], as the app does.
  bool pullHook = true;

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

  /// A sync as the app runs it: the cycle, then what the app does once it
  /// succeeded (`_afterSync` in providers.dart) unless [ensure] is false.
  Future<void> appSync({bool ensure = true}) async {
    await sync();
    await run((_) async {
      if (ensure) await schedule.ensureScheduled();
      await reminders.reconcile();
    });
  }

  /// A start or a resume: the app's maintenance step, then the reminders.
  Future<void> resume() => run((_) async {
    await schedule.ensureScheduled();
    await reminders.reconcile();
  });

  /// This device's pending doses of [prescriptionId] from now on, by id.
  Future<Map<String, DateTime>> upcoming(String prescriptionId) => run((
    db,
  ) async {
    final now = DateTime.now();
    final rows = await doseLogLocal.getDoseLogsByPrescription(prescriptionId);
    return {
      for (final d in rows)
        if (d.status == DoseStatus.pending && d.scheduledTime.isAfter(now))
          d.id: d.scheduledTime,
    };
  });

  /// The reminders this device holds for [prescriptionId]'s doses.
  Future<Map<String, DateTime>> remindersFor(String prescriptionId) async {
    final ids = (await slots(
      prescriptionId,
    )).map((s) => s.split('@').first).toSet();
    return {
      for (final e in port.live.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
  }

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
    Future<void> Function(Database db, SeededPrescription p)? beforePush,
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
      await beforePush?.call(db, seeded);
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
      final key = await device.cursors.pullKey('dose_logs');
      expect(key!.xid, greaterThan(1000), reason: device.name);
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

  group('a prescription made or changed on the other device', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    /// B's doses and reminders of [p] match A's schedule exactly.
    Future<void> expectBMatchesA(String prescriptionId) async {
      final onA = await h.a.slots(prescriptionId);
      expect(onA, isNotEmpty);
      expect(await h.b.slots(prescriptionId), onA, reason: 'doses on B');
      final upcoming = await h.a.upcoming(prescriptionId);
      expect(upcoming, isNotEmpty);
      expect(await h.b.remindersFor(prescriptionId), upcoming);
      // Every dose reached the server once; a schedule change leaves the
      // old pending rows there as tombstones, at other times.
      final onServer = h.server.dosesOf(prescriptionId).toList();
      final serverIds = {for (final r in onServer) r['id']};
      expect(serverIds, containsAll(onA.map((s) => s.split('@').first)));
      final times = [for (final r in onServer) r['scheduled_time']];
      expect(times.toSet(), hasLength(times.length), reason: 'duplicates');
    }

    test('created on A for tomorrow: B gets its doses and reminders on the '
        'sync that pulls it', () async {
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1, 8),
        durationDays: 3,
      );
      await h.b.appSync(ensure: false);
      await expectBMatchesA(p.prescriptionId);
    });

    test('created on A starting today, while B is running', () async {
      await h.b.resume();
      final p = await h.createOnA(start: today, durationDays: 2);
      await h.b.appSync(ensure: false);
      await expectBMatchesA(p.prescriptionId);
    });

    test('times changed on A: B drops the old times and reminds at the new '
        'ones', () async {
      final p = await h.createOnA(
        start: today,
        durationDays: 3,
        scheduleType: 'times_per_day',
        times: '["08:00","20:00"]',
      );
      await h.b.appSync();
      expect(await h.b.remindersFor(p.prescriptionId), isNotEmpty);
      // B takes a dose of it; the take reaches A.
      final takenId = scheduledDoseId(
        p.prescriptionId,
        DateTime(today.year, today.month, today.day, 8),
      );
      await h.b.run((_) => h.b.doses.markDoseTaken(takenId));
      await h.a.sync();

      await h.a.run((db) async {
        await db.update(
          'prescriptions',
          {
            'schedule_times': '["09:00","21:00"]',
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [p.prescriptionId],
        );
        await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
        await h.a.service.syncAll();
      });
      await h.b.appSync(ensure: false);

      await expectBMatchesA(p.prescriptionId);
      final hours = (await h.b.remindersFor(
        p.prescriptionId,
      )).values.map((t) => t.hour).toSet();
      expect(hours.difference({9, 21}), isEmpty);
      // The take made on B survived the change on both devices.
      for (final device in [h.a, h.b]) {
        expect(
          (await device.row('dose_logs', takenId))['status'],
          'taken',
          reason: device.name,
        );
      }
      // The taken dose keeps its old time on both devices.
      expect(await h.b.slots(p.prescriptionId), contains(startsWith(takenId)));
    });

    test('extended on A: B gets the extra days', () async {
      final p = await h.createOnA(start: today);
      await h.b.appSync(ensure: false);
      await h.a.run((db) async {
        await db.update(
          'prescriptions',
          {
            'duration_days': 3,
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [p.prescriptionId],
        );
        await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
        await h.a.service.syncAll();
      });
      await h.b.appSync(ensure: false);
      expect(await h.a.slots(p.prescriptionId), hasLength(9));
      await expectBMatchesA(p.prescriptionId);
    });

    test('switched to as-needed on A: B drops its pending doses and '
        'reminders', () async {
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1, 8),
        durationDays: 2,
      );
      await h.b.appSync();
      expect(await h.b.remindersFor(p.prescriptionId), hasLength(6));
      await h.a.run((db) async {
        await db.update(
          'prescriptions',
          {
            'schedule_type': 'as_needed',
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [p.prescriptionId],
        );
        await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
        await h.a.service.syncAll();
      });
      await h.b.appSync(ensure: false);
      expect(await h.a.slots(p.prescriptionId), isEmpty);
      expect(await h.b.slots(p.prescriptionId), isEmpty);
      expect(await h.b.remindersFor(p.prescriptionId), isEmpty);
    });

    test(
      'B pulls the doses A generated, with no generation of its own',
      () async {
        h.b.pullHook = false;
        final p = await h.createOnA(
          start: DateTime(today.year, today.month, today.day + 1, 8),
          durationDays: 3,
        );
        await h.b.appSync(ensure: false);
        await expectBMatchesA(p.prescriptionId);
      },
    );

    test('a prescription B holds without doses gets them on resume', () async {
      // B holds it without its doses, as a build before sync v2 left it.
      h.b.pullHook = false;
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1, 8),
        durationDays: 3,
      );
      await h.b.appSync(ensure: false);
      await h.b.run(
        (db) => db.delete(
          'dose_logs',
          where: 'prescription_id = ?',
          whereArgs: [p.prescriptionId],
        ),
      );
      expect(await h.b.slots(p.prescriptionId), isEmpty);
      h.b.pullHook = true;

      await h.b.resume();
      await h.b.appSync(ensure: false);
      await expectBMatchesA(p.prescriptionId);
    });

    test('a schedule B holds at other times, with as many doses a day, is '
        'regenerated on resume', () async {
      h.b.pullHook = false;
      final p = await h.createOnA(
        start: today,
        durationDays: 3,
        scheduleType: 'times_per_day',
        times: '["08:00","20:00"]',
      );
      await h.b.appSync(ensure: false);
      // B generated the schedule, then pulled a change of its times with a
      // build that did not regenerate.
      await h.b.run((_) async {
        await h.b.doses.generateDoseLogsForPrescription(p.prescriptionId);
      });
      await h.a.run((db) async {
        await db.update(
          'prescriptions',
          {
            'schedule_times': '["09:00","21:00"]',
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [p.prescriptionId],
        );
        await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
        await h.a.service.syncAll();
      });
      await h.b.appSync(ensure: false);
      h.b.pullHook = true;
      // A's regeneration dropped the old six on the server too, so B holds
      // only the new ones.
      expect(await h.b.slots(p.prescriptionId), hasLength(6));

      await h.b.resume();
      await h.b.appSync(ensure: false);
      await expectBMatchesA(p.prescriptionId);
    });

    test('pending doses at times the schedule no longer has are dropped on '
        'resume', () async {
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1, 8),
      );
      await h.b.appSync(ensure: false);
      // A full pull brought a dose A dropped from an earlier schedule.
      final leftover = await h.b.run(
        (db) => seedDoseLog(
          db,
          p.prescriptionId,
          DateTime(today.year, today.month, today.day + 1, 11),
        ),
      );
      await h.b.run((_) => h.b.reminders.reconcile());
      expect(await h.b.remindersFor(p.prescriptionId), contains(leftover));

      await h.b.resume();
      await expectBMatchesA(p.prescriptionId);
    });

    for (final correctsFirst in [true, false]) {
      test('a slot an older build stored hours off moves back, and a take '
          'made on the other device is kept (S-1, '
          '${correctsFirst ? 'A corrects' : 'B takes'} first)', () async {
        final start = DateTime(today.year, today.month, today.day + 1, 8);
        final slot = start.add(const Duration(hours: 8));
        final shifted = slot.add(const Duration(hours: 2));
        late String doseId;
        // As an older build left it: one generated slot reached the server
        // two hours off, under its own id.
        h.a.online = false;
        await h.createOnA(
          start: start,
          beforePush: (db, p) async {
            doseId = scheduledDoseId(p.prescriptionId, slot);
            await db.update(
              'dose_logs',
              {'scheduled_time': shifted.toIso8601String()},
              where: 'id = ?',
              whereArgs: [doseId],
            );
          },
        );
        h.a.online = true;
        await h.a.sync();
        await h.b.appSync(ensure: false);
        expect(
          DateTime.parse(
            (await h.b.row('dose_logs', doseId))['scheduled_time'] as String,
          ),
          shifted,
        );

        if (correctsFirst) {
          // B takes the dose before it hears of the correction.
          h.b.online = false;
          await h.b.run((_) => h.b.doses.markDoseTaken(doseId));
          await h.a.resume();
          expect(
            DateTime.parse(
              h.server.doses.table.rows[doseId]!['scheduled_time'] as String,
            ).toLocal(),
            slot,
          );
          h.b.online = true;
          await h.b.sync();
        } else {
          // B's take reaches the server; A corrects its stale copy offline.
          await h.b.run((_) => h.b.doses.markDoseTaken(doseId));
          h.a.online = false;
          await h.a.resume();
          h.a.online = true;
          await h.a.sync();
        }
        await h.b.sync();
        await h.a.sync();

        final server = h.server.doses.table.rows[doseId]!;
        expect(server['status'], 'taken');
        expect(
          DateTime.parse(server['scheduled_time'] as String).toLocal(),
          slot,
        );
        final times = server['field_edited_at'] as Map;
        expect(times['scheduled_time'], containsPair('auto', true));
        expect(times['status'], containsPair('auto', false));
        for (final device in [h.a, h.b]) {
          final row = await device.row('dose_logs', doseId);
          expect(
            [
              row['status'],
              DateTime.parse(row['scheduled_time'] as String),
              row['sync_status'],
            ],
            ['taken', slot, SyncStatus.synced],
            reason: device.name,
          );
        }
        // Nothing is left to correct or to send.
        await h.a.resume();
        await h.b.resume();
        expect(
          h.server.doses.table.rows[doseId]!['row_version'],
          server['row_version'],
        );
      });

      test(
        'a slot A drops from its schedule while B takes it stays taken '
        'everywhere (S-6, ${correctsFirst ? 'A' : 'B'} syncs first)',
        () async {
          final p = await h.createOnA(
            start: today.add(const Duration(days: 1)),
            durationDays: 2,
            scheduleType: 'times_per_day',
            times: '["08:00","20:00"]',
          );
          await h.b.appSync();
          final doseId = scheduledDoseId(
            p.prescriptionId,
            DateTime(today.year, today.month, today.day + 1, 20),
          );
          final dropped = scheduledDoseId(
            p.prescriptionId,
            DateTime(today.year, today.month, today.day + 2, 20),
          );
          // Both change the dose before either hears of the other's change.
          h.a.online = false;
          h.b.online = false;
          await h.b.run((_) => h.b.doses.markDoseTaken(doseId));
          await h.a.run((db) async {
            await db.update(
              'prescriptions',
              {
                'schedule_times': '["08:00","21:00"]',
                'sync_status': SyncStatus.pendingUpdate,
                'updated_at': DateTime.now().toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [p.prescriptionId],
            );
            await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
          });
          h.a.online = true;
          h.b.online = true;
          for (final device in correctsFirst ? [h.a, h.b] : [h.b, h.a]) {
            await device.sync();
          }
          await h.a.appSync();
          await h.b.appSync();
          await h.a.sync();

          final server = h.server.doses.table.rows[doseId]!;
          expect([server['status'], server['deleted_at']], ['taken', null]);
          // The slot nobody took is gone from the server.
          expect(h.server.doses.table.rows[dropped]!['deleted_at'], isNotNull);
          for (final device in [h.a, h.b]) {
            final row = await device.row('dose_logs', doseId);
            expect(
              [row['status'], row['sync_status']],
              ['taken', SyncStatus.synced],
              reason: device.name,
            );
            expect(
              await device.slots(p.prescriptionId),
              isNot(contains(startsWith(dropped))),
              reason: device.name,
            );
          }
          expect(
            await h.b.slots(p.prescriptionId),
            await h.a.slots(p.prescriptionId),
          );
        },
      );
    }

    /// A changes [p]'s times of day to [times] and regenerates, as the
    /// prescription sheet does.
    Future<void> changeTimesOnA(String prescriptionId, String times) =>
        h.a.run((db) async {
          await db.update(
            'prescriptions',
            {
              'schedule_times': times,
              'sync_status': SyncStatus.pendingUpdate,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [prescriptionId],
          );
          await h.a.doses.regenerateDoseLogsForPrescription(prescriptionId);
          await h.a.service.syncAll();
        });

    test('a schedule changed and changed back keeps its doses and '
        'reminders on both devices (I-1)', () async {
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1),
        durationDays: 2,
        scheduleType: 'times_per_day',
        times: '["08:00","20:00"]',
      );
      await h.b.appSync();
      final evening = scheduledDoseId(
        p.prescriptionId,
        DateTime(today.year, today.month, today.day + 1, 20),
      );
      await changeTimesOnA(p.prescriptionId, '["08:00","21:00"]');
      await h.b.appSync(ensure: false);
      expect(h.server.doses.table.rows[evening]!['deleted_at'], isNotNull);
      expect(await h.b.slots(p.prescriptionId), hasLength(4));

      await changeTimesOnA(p.prescriptionId, '["08:00","20:00"]');
      await h.b.appSync(ensure: false);
      await h.a.appSync();

      expect(h.server.doses.table.rows[evening]!['deleted_at'], isNull);
      await expectBMatchesA(p.prescriptionId);
      expect(await h.b.slots(p.prescriptionId), contains(startsWith(evening)));
      expect(await h.b.remindersFor(p.prescriptionId), contains(evening));
      // Nothing is left to send, and nothing comes back and forth.
      final versions = {
        for (final r in h.server.dosesOf(p.prescriptionId))
          r['id']: r['row_version'],
      };
      for (var i = 0; i < 2; i++) {
        await h.a.resume();
        await h.b.resume();
        await h.a.appSync();
        await h.b.appSync();
      }
      expect({
        for (final r in h.server.dosesOf(p.prescriptionId))
          r['id']: r['row_version'],
      }, versions);
      for (final device in [h.a, h.b]) {
        expect(await device.slots(p.prescriptionId), hasLength(4));
        expect(
          (await device.row('dose_logs', evening))['sync_status'],
          SyncStatus.synced,
          reason: device.name,
        );
      }
    });

    group('A cannot send its doses yet: B generates them from the pulled '
        'prescription', () {
      var doseTableDown = false;
      setUp(() {
        h.server.doses.rows.beforeCall = () async {
          if (doseTableDown) throw StateError('the dose table is unreachable');
        };
      });

      test('a new prescription (review X5)', () async {
        doseTableDown = true;
        final p = await h.createOnA(
          start: DateTime(today.year, today.month, today.day + 1, 8),
          durationDays: 2,
        );
        expect(h.server.dosesOf(p.prescriptionId), isEmpty);
        doseTableDown = false;
        await h.b.appSync(ensure: false);
        final onB = await h.b.slots(p.prescriptionId);
        expect(onB, hasLength(6));
        expect(await h.b.remindersFor(p.prescriptionId), hasLength(6));
        await h.a.appSync();
        expect(await h.a.slots(p.prescriptionId), onB);
      });

      test('times changed, and nothing else (review X4)', () async {
        final p = await h.createOnA(
          start: DateTime(today.year, today.month, today.day + 1),
          durationDays: 2,
          scheduleType: 'times_per_day',
          times: '["08:00","20:00"]',
        );
        await h.b.appSync();
        doseTableDown = true;
        await h.a.run((db) async {
          await db.update(
            'prescriptions',
            {
              'schedule_times': '["09:00","21:00"]',
              'sync_status': SyncStatus.pendingUpdate,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [p.prescriptionId],
          );
          await h.a.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
          await h.a.service.syncAll();
        });
        expect(
          h.server.prescriptions.table.rows[p
              .prescriptionId]!['schedule_times'],
          '["09:00","21:00"]',
        );
        doseTableDown = false;
        await h.b.appSync(ensure: false);
        final hours = {
          for (final s in await h.b.slots(p.prescriptionId))
            DateTime.parse(s.split('@').last).hour,
        };
        expect(hours, {9, 21});
        expect(
          (await h.b.remindersFor(
            p.prescriptionId,
          )).values.map((t) => t.hour).toSet(),
          {9, 21},
        );
      });
    });

    test('times changed while the first batch of new doses is on its way: '
        'the dropped doses end deleted, as the app\'s own, everywhere, with '
        'no reminders (cycle review I-1)', () async {
      const newTimes = '["09:00","15:00","21:00"]';
      late String pid;
      var armed = false;
      var fired = false;
      h.server.doses.rows.beforeCall = () async {
        if (!armed || fired) return;
        fired = true;
        // The person changes the times on A while A's first batch of 100
        // is being sent (the database is A's: the cycle runs on it).
        final db = await AppDatabase.instance.database;
        await db.update(
          'prescriptions',
          {
            'schedule_times': newTimes,
            'sync_status': SyncStatus.pendingUpdate,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [pid],
        );
        await h.a.doses.regenerateDoseLogsForPrescription(pid);
      };
      // 60 days, three a day: two batches.
      h.a.online = false;
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1),
        durationDays: 60,
        scheduleType: 'times_per_day',
        times: '["08:00","14:00","20:00"]',
        beforePush: (db, s) async => pid = s.prescriptionId,
      );
      h.a.online = true;
      armed = true;
      await h.a.sync();
      expect(fired, isTrue);

      bool onSchedule(DateTime local) => {9, 15, 21}.contains(local.hour);
      DateTime localTime(Map<String, dynamic> r) =>
          DateTime.parse(r['scheduled_time'] as String).toLocal();
      Future<void> expectClean(String when) async {
        final rows = h.server.dosesOf(p.prescriptionId).toList();
        final stray = [
          for (final r in rows)
            if (r['deleted_at'] == null && !onSchedule(localTime(r))) r['id'],
        ];
        expect(stray, isEmpty, reason: 'live doses at the old times, $when');
        for (final r in rows.where((r) => !onSchedule(localTime(r)))) {
          expect(
            r['edited_at'],
            startsWith('1970-01-01'),
            reason: 'a dropped dose is the app\'s own delete, $when',
          );
        }
      }

      await expectClean('after A\'s cycle');
      await h.a.appSync();
      await expectClean('after A\'s app sync');
      await h.b.appSync(ensure: false);
      final onA = await h.a.slots(p.prescriptionId);
      expect(onA, isNotEmpty);
      expect(
        {
          for (final r in h.server.dosesOf(p.prescriptionId))
            if (r['deleted_at'] == null) r['id'],
        },
        {for (final s in onA) s.split('@').first},
        reason: 'the server holds exactly A\'s doses',
      );
      for (final device in [h.a, h.b]) {
        final slots = await device.slots(p.prescriptionId);
        expect(slots, onA, reason: device.name);
        expect(
          slots.where((s) => !onSchedule(DateTime.parse(s.split('@').last))),
          isEmpty,
          reason: device.name,
        );
        final reminders = await device.remindersFor(p.prescriptionId);
        expect(reminders, isNotEmpty, reason: device.name);
        expect(
          reminders.values.where((t) => !onSchedule(t)),
          isEmpty,
          reason: '${device.name}: no reminder at an old time',
        );
      }
      // Nothing left to send, and nothing moves on later rounds.
      final versions = {
        for (final r in h.server.dosesOf(p.prescriptionId))
          r['id']: r['row_version'],
      };
      for (var i = 0; i < 2; i++) {
        await h.a.appSync();
        await h.b.appSync();
      }
      await expectClean('after two more rounds');
      expect({
        for (final r in h.server.dosesOf(p.prescriptionId))
          r['id']: r['row_version'],
      }, versions);
      for (final device in [h.a, h.b]) {
        await device.run((db) async {
          expect(
            await db.query(
              'dose_logs',
              where: 'sync_status != ?',
              whereArgs: [SyncStatus.synced],
            ),
            isEmpty,
            reason: device.name,
          );
        });
      }
    });

    group('an undo made offline, then the slot dropped on the same device '
        '(cycle review I-2)', () {
      late SeededPrescription p;
      late String evening;

      /// A takes tomorrow evening's dose; B pulls it, then, offline, undoes
      /// the take and moves the evening dose to 21:00.
      Future<void> undoThenMove() async {
        p = await h.createOnA(
          start: DateTime(today.year, today.month, today.day + 1),
          durationDays: 2,
          scheduleType: 'times_per_day',
          times: '["08:00","20:00"]',
        );
        await h.b.appSync();
        evening = scheduledDoseId(
          p.prescriptionId,
          DateTime(today.year, today.month, today.day + 1, 20),
        );
        await h.a.run((_) => h.a.doses.markDoseTaken(evening));
        await h.b.appSync();
        expect((await h.b.row('dose_logs', evening))['status'], 'taken');
        h.b.online = false;
        await h.b.run((db) async {
          await h.b.doses.markDosePending(evening);
          await db.update(
            'prescriptions',
            {
              'schedule_times': '["08:00","21:00"]',
              'sync_status': SyncStatus.pendingUpdate,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [p.prescriptionId],
          );
          await h.b.doses.regenerateDoseLogsForPrescription(p.prescriptionId);
        });
      }

      /// The evening dose at 20:00 is gone from the server and from both
      /// devices, with no reminder, and later rounds move nothing.
      Future<void> expectDroppedEverywhere() async {
        final server = h.server.doses.table.rows[evening]!;
        expect(server['deleted_at'], isNotNull, reason: 'server');
        expect(server['status'], 'pending', reason: 'the undo went out');
        for (final device in [h.a, h.b]) {
          expect(
            await device.slots(p.prescriptionId),
            isNot(contains(startsWith(evening))),
            reason: device.name,
          );
          expect(
            await device.remindersFor(p.prescriptionId),
            isNot(contains(evening)),
            reason: device.name,
          );
          expect(
            (await device.remindersFor(
              p.prescriptionId,
            )).values.map((t) => t.hour).toSet().difference({8, 21}),
            isEmpty,
            reason: device.name,
          );
        }
        final versions = {
          for (final r in h.server.dosesOf(p.prescriptionId))
            r['id']: r['row_version'],
        };
        for (var i = 0; i < 2; i++) {
          await h.a.appSync();
          await h.b.appSync();
        }
        expect({
          for (final r in h.server.dosesOf(p.prescriptionId))
            r['id']: r['row_version'],
        }, versions);
        for (final device in [h.a, h.b]) {
          await device.run((db) async {
            expect(
              await db.query(
                'dose_logs',
                where: 'sync_status != ?',
                whereArgs: [SyncStatus.synced],
              ),
              isEmpty,
              reason: device.name,
            );
          });
        }
      }

      test('the undo beats the earlier take, and the slot is dropped '
          'everywhere', () async {
        await undoThenMove();
        h.b.online = true;
        await h.b.appSync();
        await h.a.appSync();
        await expectDroppedEverywhere();
      });

      test('the slot is gone on B at once, even when B starts again before '
          'it is online', () async {
        await undoThenMove();
        await h.b.resume();
        expect(
          await h.b.slots(p.prescriptionId),
          isNot(contains(startsWith(evening))),
          reason: 'B, offline',
        );
        expect(
          await h.b.remindersFor(p.prescriptionId),
          isNot(contains(evening)),
          reason: 'B, offline',
        );
        h.b.online = true;
        await h.b.appSync();
        await h.a.appSync();
        await expectDroppedEverywhere();
      });

      test('a take on A after the undo still wins', () async {
        await undoThenMove();
        // A took the dose again after B's undo (and after its first take).
        await h.a.run((_) => h.a.doses.markDosePending(evening));
        await h.a.run((_) => h.a.doses.markDoseTaken(evening));
        h.b.online = true;
        await h.b.appSync();
        await h.a.appSync();
        expect(h.server.doses.table.rows[evening]!['status'], 'taken');
        expect(h.server.doses.table.rows[evening]!['deleted_at'], isNull);
        for (final device in [h.a, h.b]) {
          expect(
            (await device.row('dose_logs', evening))['status'],
            'taken',
            reason: device.name,
          );
          expect(
            (await device.row('dose_logs', evening))['sync_status'],
            SyncStatus.synced,
            reason: device.name,
          );
        }
      });
    });

    for (final bTakes in [false, true]) {
      test('a prescription deleted on A while B, offline, '
          '${bTakes ? 'takes a dose' : 'generates the next days'}: the '
          'delete wins, and both devices keep syncing (C-1)', () async {
        final p = await h.createOnA(
          start: DateTime(today.year, today.month, today.day + 1, 8),
          durationDays: 2,
        );
        await h.b.appSync();
        final first = scheduledDoseId(
          p.prescriptionId,
          DateTime(today.year, today.month, today.day + 1, 8),
        );
        h.b.online = false;
        await h.b.run((db) async {
          if (bTakes) await h.b.doses.markDoseTaken(first);
          // A longer course, generated before the change is sent.
          await db.update(
            'prescriptions',
            {'duration_days': 4},
            where: 'id = ?',
            whereArgs: [p.prescriptionId],
          );
          await h.b.doses.generateDoseLogsForPrescription(p.prescriptionId);
        });
        await h.a.run((db) async {
          await PrescriptionRepositoryImpl(
            localDatasource: h.a.prescriptionLocal,
          ).deletePrescription(p.prescriptionId);
          await h.a.service.syncAll();
        });
        h.b.online = true;
        for (var i = 0; i < 2; i++) {
          final onB = (await h.b.run((_) async => h.b.service.syncAll()))!;
          final onA = (await h.a.run((_) async => h.a.service.syncAll()))!;
          expect(onB.failures, isEmpty, reason: 'B, round $i');
          expect(onA.failures, isEmpty, reason: 'A, round $i');
        }
        await h.a.appSync();
        await h.b.appSync();

        expect(
          h.server
              .dosesOf(p.prescriptionId)
              .where((r) => r['deleted_at'] == null),
          isEmpty,
        );
        if (bTakes) {
          expect(h.server.doses.table.rows[first]!['status'], 'taken');
        }
        for (final device in [h.a, h.b]) {
          expect(
            await device.slots(p.prescriptionId),
            isEmpty,
            reason: device.name,
          );
          expect(await device.remindersFor(p.prescriptionId), isEmpty);
          await device.run((db) async {
            expect(
              await db.query(
                'prescriptions',
                where: 'id = ?',
                whereArgs: [p.prescriptionId],
              ),
              isEmpty,
              reason: device.name,
            );
          });
        }
      });
    }

    test('a slot the server holds a tombstone for is not generated again '
        'after every sync', () async {
      final p = await h.createOnA(
        start: DateTime(today.year, today.month, today.day + 1, 8),
      );
      final gone = scheduledDoseId(
        p.prescriptionId,
        DateTime(today.year, today.month, today.day + 1, 8),
      );
      h.server.doses.table.tombstone(gone);
      await h.a.run((db) async {
        await db.delete('dose_logs', where: 'id = ?', whereArgs: [gone]);
      });
      h.b.pullHook = false;
      await h.b.appSync(ensure: false);
      h.b.pullHook = true;

      final before = h.server.doses.table.insertBatches.length;
      for (var i = 0; i < 4; i++) {
        await h.b.appSync();
      }
      expect(await h.b.slots(p.prescriptionId), hasLength(2));
      // One attempt that brought the tombstone back, then nothing.
      expect(h.server.doses.table.insertBatches.length - before, 1);
    });
  });

  group('a row created offline, long before it is pushed', () {
    final hourAgo = DateTime.now().subtract(const Duration(hours: 1));

    test('an as-needed intake reaches a device that synced since', () async {
      final p = await h.createOnA(
        start: DateTime(2026, 3, 1, 8),
        scheduleType: 'as_needed',
      );
      await h.b.sync();
      h.a.online = false;
      const intake = 'intake-1';
      await h.a.run(
        (_) => h.a.doses.addDoseLog(
          DoseLog(
            id: intake,
            prescriptionId: p.prescriptionId,
            scheduledTime: hourAgo,
            takenTime: hourAgo,
            status: DoseStatus.taken,
            createdAt: hourAgo,
            updatedAt: hourAgo,
          ),
        ),
      );
      // B syncs meanwhile: its cursors move past the intake's time.
      await h.b.sync();
      h.a.online = true;
      await h.a.sync();
      await h.b.sync();

      final onB = await h.b.row('dose_logs', intake);
      expect(onB['status'], 'taken');
      expect(onB['sync_status'], SyncStatus.synced);
      final onA = await h.a.row('dose_logs', intake);
      expect(onA['sync_status'], SyncStatus.synced);
      // A keeps the stamp the server gave the intake.
      expect(
        DateTime.parse(
          onA['updated_at']! as String,
        ).isAfter(hourAgo.add(const Duration(minutes: 30))),
        isTrue,
      );
    });

    test('a prescription reaches a device that synced since, with its '
        'doses', () async {
      final now = DateTime.now();
      h.a.online = false;
      final p = await h.createOnA(
        start: DateTime(now.year, now.month, now.day + 1, 8),
      );
      await h.a.run((db) async {
        for (final (table, id) in [
          ('medications', p.medicationId),
          ('treatments', p.treatmentId),
          ('prescriptions', p.prescriptionId),
        ]) {
          await db.update(
            table,
            {'updated_at': hourAgo.toIso8601String()},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
      await h.b.sync();
      h.a.online = true;
      await h.a.sync();
      await h.b.appSync(ensure: false);

      expect(
        (await h.b.row('prescriptions', p.prescriptionId))['treatment_id'],
        p.treatmentId,
      );
      expect(
        await h.b.slots(p.prescriptionId),
        await h.a.slots(p.prescriptionId),
      );
    });
  });
}
