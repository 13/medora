/// Every local write stamps when it was made (`edited_at`), so a merge can
/// tell a person's change from an older one, and from the app's own
/// (1970). A row stored from the server is left to the sync cycle.
///
/// The stamp is UTC text (`…Z`) from the datasource's clock, never later
/// than that clock. Run these under `TZ=Europe/Rome` as well: naive local
/// text only goes wrong in a zone with daylight saving.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

typedef _Ids = ({SeededPrescription p, String doseId});

/// One synced table and its write paths, each built on the clock [now].
class _Case {
  const _Case({
    required this.table,
    required this.idOf,
    required this.upsert,
    required this.markDeleted,
    this.edit,
    this.editedColumns = const {},
  });

  final String table;
  final String Function(_Ids ids) idOf;
  final Future<void> Function(
    Now now,
    _Ids ids,
    String syncStatus,
    DateTime? updatedAt, {
    String? notes,
  })
  upsert;
  final Future<void> Function(Now now, String id) markDeleted;

  /// The table's own edit path, when it has one besides [upsert].
  final Future<void> Function(Now now, String id)? edit;

  /// The columns [edit] changes.
  final Set<String> editedColumns;
}

final _cases = [
  _Case(
    table: 'medications',
    idOf: (ids) => ids.p.medicationId,
    upsert: (now, ids, status, at, {notes}) =>
        MedicationLocalDatasource(now: now).upsert(
          MedicationModel(
            id: ids.p.medicationId,
            name: 'Ibu',
            quantity: 1,
            notes: notes,
            updatedAt: at,
          ),
          syncStatus: status,
        ),
    markDeleted: (now, id) =>
        MedicationLocalDatasource(now: now).markDeleted(id),
    edit: (now, id) async {
      expect(
        await MedicationLocalDatasource(now: now).archiveMedication(id),
        isTrue,
      );
    },
    editedColumns: {'is_archived'},
  ),
  _Case(
    table: 'treatments',
    idOf: (ids) => ids.p.treatmentId,
    upsert: (now, ids, status, at, {notes}) =>
        TreatmentLocalDatasource(now: now).upsert(
          TreatmentModel(
            id: ids.p.treatmentId,
            name: 'Flu',
            startDate: DateTime(2026, 3),
            notes: notes,
            updatedAt: at,
          ),
          syncStatus: status,
        ),
    markDeleted: (now, id) =>
        TreatmentLocalDatasource(now: now).markDeleted(id),
  ),
  _Case(
    table: 'prescriptions',
    idOf: (ids) => ids.p.prescriptionId,
    upsert: (now, ids, status, at, {notes}) =>
        PrescriptionLocalDatasource(now: now).upsert(
          PrescriptionModel(
            id: ids.p.prescriptionId,
            treatmentId: ids.p.treatmentId,
            medicationId: ids.p.medicationId,
            dosage: '1 tablet',
            startTime: DateTime(2026, 3, 1, 8),
            notes: notes,
            updatedAt: at,
          ),
          syncStatus: status,
        ),
    markDeleted: (now, id) =>
        PrescriptionLocalDatasource(now: now).markDeleted(id),
    edit: (now, id) async {
      expect(
        await PrescriptionLocalDatasource(now: now).deactivate(id),
        isTrue,
      );
    },
    editedColumns: {'is_active'},
  ),
  _Case(
    table: 'dose_logs',
    idOf: (ids) => ids.doseId,
    upsert: (now, ids, status, at, {notes}) =>
        DoseLogLocalDatasource(now: now).upsert(
          DoseLogModel(
            id: ids.doseId,
            prescriptionId: ids.p.prescriptionId,
            scheduledTime: DateTime(2026, 3, 1, 8),
            notes: notes,
            updatedAt: at,
          ),
          syncStatus: status,
        ),
    markDeleted: (now, id) => DoseLogLocalDatasource(now: now).markDeleted(id),
    edit: (now, id) => DoseLogLocalDatasource(now: now).updateStatus(
      id,
      'taken',
      takenTime: DateTime(2026, 3, 1, 8, 5),
      syncStatus: SyncStatus.pendingUpdate,
    ),
    editedColumns: {'status', 'taken_time'},
  ),
];

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  // The phone's clock. Like `DateTime.now()`, it reads local time.
  late DateTime clock;
  DateTime now() => clock.toLocal();

  late _Ids ids;
  setUp(() async {
    clock = DateTime.utc(2026, 3, 5, 8);
    final db = await AppDatabase.instance.database;
    final p = await seedPrescription(db);
    ids = (p: p, doseId: await seedDoseLog(db, p.prescriptionId, clock));
    // The seeds are stamped with the real clock; start before [clock].
    for (final c in _cases) {
      await db.update(c.table, {'updated_at': '2026-03-01T00:00:00.000Z'});
    }
  });

  Future<Map<String, Object?>> row(String table, String id) async =>
      (await (await AppDatabase.instance.database).query(
        table,
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  Future<Object?> editedAt(_Case c) async =>
      (await row(c.table, c.idOf(ids)))['edited_at'];

  /// The row's stored edit times per column.
  Future<Map<String, FieldTime>> times(String table, String id) async =>
      FieldTimes.decode((await row(table, id))['field_edited_at']).entries;

  /// The seeds' time: they carry no edit time, so their `updated_at`.
  final seeded = FieldTime(DateTime.utc(2026, 3));

  for (final c in _cases) {
    group(c.table, () {
      test('a pending upsert stores the model stamp, in UTC', () async {
        await c.upsert(
          now,
          ids,
          SyncStatus.pendingUpdate,
          DateTime.utc(2026, 3, 5, 7, 30).toLocal(),
        );
        expect(await editedAt(c), '2026-03-05T07:30:00.000Z');
      });

      test('a pending upsert with no stamp, or one still to come, is '
          'stamped now', () async {
        clock = DateTime.utc(2026, 3, 5, 8, 10);
        await c.upsert(now, ids, SyncStatus.pendingUpdate, null);
        expect(await editedAt(c), '2026-03-05T08:10:00.000Z');

        await c.upsert(
          now,
          ids,
          SyncStatus.pendingUpdate,
          DateTime.utc(2026, 3, 5, 9).toLocal(),
        );
        expect(
          await editedAt(c),
          '2026-03-05T08:10:00.000Z',
          reason: 'an edit time is never later than the clock',
        );
      });

      test('a synced upsert leaves the column alone', () async {
        final db = await AppDatabase.instance.database;
        await db.update(
          c.table,
          {'edited_at': '2026-03-01T00:00:00.000Z'},
          where: 'id = ?',
          whereArgs: [c.idOf(ids)],
        );
        await c.upsert(
          now,
          ids,
          SyncStatus.synced,
          DateTime.utc(2026, 3, 5, 7).toLocal(),
        );
        expect(await editedAt(c), '2026-03-01T00:00:00.000Z');
      });

      test('a delete stamps now once, and a second delete changes '
          'nothing', () async {
        clock = DateTime.utc(2026, 3, 5, 8, 15);
        await c.markDeleted(now, c.idOf(ids));
        final deleted = await row(c.table, c.idOf(ids));
        expect(deleted['sync_status'], SyncStatus.pendingDelete);
        expect(deleted['edited_at'], '2026-03-05T08:15:00.000Z');
        expect(
          DateTime.parse(deleted['deleted_at']! as String).toUtc(),
          DateTime.utc(2026, 3, 5, 8, 15),
        );

        clock = DateTime.utc(2026, 3, 5, 9);
        await c.markDeleted(now, c.idOf(ids));
        final again = await row(c.table, c.idOf(ids));
        expect(
          [again['edited_at'], again['deleted_at']],
          [deleted['edited_at'], deleted['deleted_at']],
        );
      });

      group('edit times per column', () {
        test('a pending upsert stamps exactly the columns it changes, and '
            'fills the others from the row\'s old time', () async {
          await c.upsert(
            now,
            ids,
            SyncStatus.pendingUpdate,
            DateTime.utc(2026, 3, 5, 7).toLocal(),
          );
          final first = await times(c.table, c.idOf(ids));
          expect(first, isNotEmpty);
          expect(first.containsKey('updated_at'), isFalse);
          expect(first.containsKey('quantity'), isFalse);
          expect(first.containsKey('id'), isFalse);
          expect(
            first.values,
            everyElement(
              isIn([seeded, FieldTime(DateTime.utc(2026, 3, 5, 7))]),
            ),
          );
          expect(first['notes'], seeded, reason: 'notes did not change');

          await c.upsert(
            now,
            ids,
            SyncStatus.pendingUpdate,
            DateTime.utc(2026, 3, 5, 7, 30).toLocal(),
            notes: 'after food',
          );
          final second = await times(c.table, c.idOf(ids));
          expect(second['notes'], FieldTime(DateTime.utc(2026, 3, 5, 7, 30)));
          expect({...second}..remove('notes'), {...first}..remove('notes'));
        });

        test('a new row stores no map: its edit time stands for every '
            'column', () async {
          final db = await AppDatabase.instance.database;
          await db.delete('dose_logs');
          if (c.table != 'dose_logs') {
            await db.delete(c.table, where: 'id = ?', whereArgs: [c.idOf(ids)]);
          }
          await c.upsert(
            now,
            ids,
            SyncStatus.pendingCreate,
            DateTime.utc(2026, 3, 5, 7).toLocal(),
          );
          final created = await row(c.table, c.idOf(ids));
          expect(created['field_edited_at'], isNull);
          expect(
            FieldTimes.decode(
              created['field_edited_at'],
              rowTime: localRowTime(created),
            ).of('notes'),
            FieldTime(DateTime.utc(2026, 3, 5, 7)),
          );
        });

        test('a synced upsert and a delete leave the map alone', () async {
          await c.upsert(
            now,
            ids,
            SyncStatus.pendingUpdate,
            DateTime.utc(2026, 3, 5, 7).toLocal(),
          );
          final before = await times(c.table, c.idOf(ids));
          await c.upsert(
            now,
            ids,
            SyncStatus.synced,
            DateTime.utc(2026, 3, 5, 7, 30).toLocal(),
            notes: 'from the server',
          );
          expect(await times(c.table, c.idOf(ids)), before);
          await c.markDeleted(now, c.idOf(ids));
          expect(await times(c.table, c.idOf(ids)), before);
        });

        if (c.edit case final edit?) {
          test('its own edit stamps exactly ${c.editedColumns}, in UTC, '
              'across the October fall-back hour', () async {
            clock = DateTime.utc(2026, 10, 25, 0, 30);
            await edit(now, c.idOf(ids));
            final first = await times(c.table, c.idOf(ids));
            for (final column in c.editedColumns) {
              expect(first[column], FieldTime(clock), reason: column);
            }
            final others = {...first}
              ..removeWhere((k, _) => c.editedColumns.contains(k));
            expect(others, isNotEmpty);
            expect(others.values.toSet(), {seeded});

            clock = DateTime.utc(2026, 10, 25, 1, 20);
            await edit(now, c.idOf(ids));
            final second = await times(c.table, c.idOf(ids));
            // The second edit changes nothing (already archived, paused,
            // taken): no entry moves, although edited_at does.
            expect(second, first);
            expect(await editedAt(c), '2026-10-25T01:20:00.000Z');
            final text =
                (await row(c.table, c.idOf(ids)))['field_edited_at']! as String;
            expect(text, contains('"2026-10-25T00:30:00.000Z"'));
          });
        }
      });
      if (c.edit case final edit?) {
        test('its own edit stamps now in UTC, the instant of '
            'updated_at', () async {
          clock = DateTime.utc(2026, 3, 5, 8, 20);
          await edit(now, c.idOf(ids));
          final edited = await row(c.table, c.idOf(ids));
          expect(edited['edited_at'], '2026-03-05T08:20:00.000Z');
          expect(
            DateTime.parse(edited['updated_at']! as String).toUtc(),
            DateTime.utc(2026, 3, 5, 8, 20),
          );
        });

        test('an edit in the October fall-back hour, after one in the '
            'summer-time hour, reads as the later one', () async {
          // 02:30 CEST, then 02:20 CET 50 minutes later (Europe/Rome).
          clock = DateTime.utc(2026, 10, 25, 0, 30);
          await edit(now, c.idOf(ids));
          final first = await editedAt(c);
          clock = DateTime.utc(2026, 10, 25, 1, 20);
          await edit(now, c.idOf(ids));
          final second = await editedAt(c);
          expect(
            [first, second],
            ['2026-10-25T00:30:00.000Z', '2026-10-25T01:20:00.000Z'],
          );
        });

        test('an edit after the phone moved zones is stamped with the '
            'real time, never one still to come', () async {
          // The last edit was made at 08:00Z in Rome, which wrote its
          // updated_at as the naive text 10:00. Read back in London (or
          // anywhere west of Rome) that text is later than 08:30Z.
          final db = await AppDatabase.instance.database;
          await db.update(
            c.table,
            {
              'updated_at': '2026-03-05T10:00:00.000',
              'edited_at': '2026-03-05T08:00:00.000Z',
            },
            where: 'id = ?',
            whereArgs: [c.idOf(ids)],
          );
          clock = DateTime.utc(2026, 3, 5, 8, 30);
          await edit(now, c.idOf(ids));
          expect(await editedAt(c), '2026-03-05T08:30:00.000Z');
        });
      }
    });
  }

  test('a generated dose carries the automatic 1970 edit time', () async {
    await DoseLogLocalDatasource(now: now).insertBatchIfAbsent([
      DoseLogModel(
        id: 'g1',
        prescriptionId: ids.p.prescriptionId,
        scheduledTime: DateTime(2026, 3, 1, 8),
        updatedAt: generatedUpdatedAt,
      ),
    ], syncStatus: SyncStatus.pendingCreate);
    expect(
      (await row('dose_logs', 'g1'))['edited_at'],
      '1970-01-01T00:00:00.000Z',
    );
  });

  test('a person\'s delete of a dose is never guarded', () async {
    final db = await AppDatabase.instance.database;
    await db.update('dose_logs', {
      'delete_guard': 'if_pending',
      'edited_at': generatedUpdatedAt.toIso8601String(),
    });
    await DoseLogLocalDatasource(now: now).markDeleted(ids.doseId);
    final dose = await row('dose_logs', ids.doseId);
    expect(dose['delete_guard'], isNull);
    expect(dose['edited_at'], '2026-03-05T08:00:00.000Z');
  });

  group('the app\'s own changes', () {
    test('a generated dose has no map: every column is automatic', () async {
      await DoseLogLocalDatasource(now: now).insertBatchIfAbsent([
        DoseLogModel(
          id: 'g1',
          prescriptionId: ids.p.prescriptionId,
          scheduledTime: DateTime(2026, 3, 1, 8),
          updatedAt: generatedUpdatedAt,
        ),
      ], syncStatus: SyncStatus.pendingCreate);
      final dose = await row('dose_logs', 'g1');
      expect(dose['field_edited_at'], isNull);
      expect(
        FieldTimes.decode(null, rowTime: localRowTime(dose)).of('status'),
        FieldTime.automaticChange,
      );
    });

    test(
      'an overdue dose marked missed: status is an automatic change, '
      'the rest keeps its time; a take after it is a person\'s again',
      () async {
        final ds = DoseLogLocalDatasource(now: now);
        final db = await AppDatabase.instance.database;
        await db.update('dose_logs', {'edited_at': '2026-03-01T06:00:00.000Z'});
        final swept = await ds.markOverduePendingAsMissed(
          DateTime.utc(2026, 3, 5, 8, 1),
        );
        expect(swept.changed, 1);
        final missed = await times('dose_logs', ids.doseId);
        expect(missed['status'], FieldTime.automaticChange);
        expect(missed['notes'], FieldTime(DateTime.utc(2026, 3, 1, 6)));
        expect(
          missed['scheduled_time'],
          FieldTime(DateTime.utc(2026, 3, 1, 6)),
        );

        clock = DateTime.utc(2026, 3, 5, 8, 30);
        await ds.updateStatus(
          ids.doseId,
          'taken',
          takenTime: clock.toLocal(),
          syncStatus: SyncStatus.pendingUpdate,
        );
        final taken = await times('dose_logs', ids.doseId);
        expect(taken['status'], FieldTime(clock));
        expect(taken['taken_time'], FieldTime(clock));
        expect(taken['notes'], missed['notes']);
      },
    );

    test('a stock change gives the stock no entry', () async {
      final ds = MedicationLocalDatasource(now: now);
      await ds.adjustQuantity(ids.p.medicationId, -1);
      final stock = await times('medications', ids.p.medicationId);
      expect(stock, isNotEmpty, reason: 'filled: edited_at moved');
      expect(stock.containsKey('quantity'), isFalse);
      expect(stock.values.toSet(), {seeded});
    });

    test('an undo clears taken_time: that is a change to it', () async {
      final ds = DoseLogLocalDatasource(now: now);
      await ds.updateStatus(
        ids.doseId,
        'taken',
        takenTime: clock.toLocal(),
        syncStatus: SyncStatus.pendingUpdate,
      );
      clock = DateTime.utc(2026, 3, 5, 8, 45);
      await ds.updateStatus(
        ids.doseId,
        'pending',
        clearTakenTime: true,
        syncStatus: SyncStatus.pendingUpdate,
      );
      final undone = await times('dose_logs', ids.doseId);
      expect(undone['status'], FieldTime(clock));
      expect(undone['taken_time'], FieldTime(clock));
    });
  });
}
