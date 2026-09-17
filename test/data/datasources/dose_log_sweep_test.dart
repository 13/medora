import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> row(String id) async =>
      (await (await AppDatabase.instance.database).query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('with sync, a synced overdue dose becomes an automatic change to '
      'push; an unpushed undo is left alone', () async {
    final db = await AppDatabase.instance.database;
    final p = (await seedPrescription(db)).prescriptionId;
    final synced = await seedDoseLog(db, p, DateTime(2026, 3, 1, 8));
    final undone = await seedDoseLog(db, p, DateTime(2026, 3, 1, 16));
    await db.update(
      'dose_logs',
      {'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: [undone],
    );

    final result = await DoseLogLocalDatasource().markOverduePendingAsMissed(
      DateTime(2026, 3, 2),
    );

    expect(result, (changed: 1, unpushed: 1));
    final s = await row(synced);
    expect(
      [s['status'], s['sync_status'], s['edited_at']],
      ['missed', 'pending_update', '1970-01-01T00:00:00.000Z'],
    );
    final u = await row(undone);
    expect([u['status'], u['sync_status']], ['pending', 'pending_update']);
  });

  test('without sync, an undone overdue dose is marked missed too, and no '
      'status changes', () async {
    final db = await AppDatabase.instance.database;
    final p = (await seedPrescription(db)).prescriptionId;
    final undone = await seedDoseLog(db, p, DateTime(2026, 3, 1, 16));
    await db.update(
      'dose_logs',
      {'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: [undone],
    );

    final result = await DoseLogLocalDatasource().markOverduePendingAsMissed(
      DateTime(2026, 3, 2),
      pushable: false,
    );

    expect(result, (changed: 1, unpushed: 0));
    final u = await row(undone);
    expect([u['status'], u['sync_status']], ['missed', 'pending_update']);
  });

  Map<String, dynamic> times(Map<String, Object?> row) =>
      jsonDecode(row['field_edited_at']! as String) as Map<String, dynamic>;

  const auto = {'at': '1970-01-01T00:00:00.000Z', 'auto': true};

  test('the swept status is marked automatic; the other columns keep the '
      "row's own time", () async {
    final db = await AppDatabase.instance.database;
    final p = (await seedPrescription(db)).prescriptionId;
    final id = await seedDoseLog(db, p, DateTime(2026, 3, 1, 8));
    await db.update(
      'dose_logs',
      {'edited_at': '2026-02-27T10:00:00.000Z'},
      where: 'id = ?',
      whereArgs: [id],
    );

    await DoseLogLocalDatasource().markOverduePendingAsMissed(
      DateTime(2026, 3, 2),
    );

    final t = times(await row(id));
    expect(t['status'], auto);
    expect(t['notes'], {'at': '2026-02-27T10:00:00.000Z', 'auto': false});
  });

  group('a dose dropped from a changed schedule', () {
    Future<(String, List<String>)> seedThree() async {
      final db = await AppDatabase.instance.database;
      final p = (await seedPrescription(db)).prescriptionId;
      final ids = [
        for (final h in [8, 12, 16])
          await seedDoseLog(db, p, DateTime(2026, 3, 1, h)),
      ];
      // The first one the server has; the second one this device sent
      // without an answer; the third one no server has seen.
      await db.update(
        'dose_logs',
        {'sync_version': 2, 'edited_at': '2026-02-27T10:00:00.000Z'},
        where: 'id = ?',
        whereArgs: [ids[0]],
      );
      await db.update(
        'dose_logs',
        {'sync_status': SyncStatus.pendingCreate, 'sync_write_id': 'w-1'},
        where: 'id = ?',
        whereArgs: [ids[1]],
      );
      await db.update(
        'dose_logs',
        {'sync_status': SyncStatus.pendingCreate},
        where: 'id = ?',
        whereArgs: [ids[2]],
      );
      return (p, ids);
    }

    Future<Map<String, Object?>?> maybeRow(String id) async {
      final rows = await (await AppDatabase.instance.database).query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [id],
      );
      return rows.isEmpty ? null : rows.single;
    }

    test('goes to the server as a guarded automatic delete once a server '
        'may have it; otherwise it is deleted here', () async {
      final (p, ids) = await seedThree();

      final dropped = await DoseLogLocalDatasource().dropPendingByPrescription(
        p,
      );

      expect(dropped, 3);
      for (final id in ids.take(2)) {
        final r = (await maybeRow(id))!;
        expect(
          [r['sync_status'], r['delete_guard'], r['edited_at']],
          [SyncStatus.pendingDelete, 'if_pending', '1970-01-01T00:00:00.000Z'],
          reason: id,
        );
        expect(r['deleted_at'], isNotNull);
      }
      // The columns keep the time they had before the row's own time
      // became the automatic one.
      expect(times((await maybeRow(ids[0]))!)['notes'], {
        'at': '2026-02-27T10:00:00.000Z',
        'auto': false,
      });
      expect(await maybeRow(ids[2]), isNull);
    });

    test('without sync, every dropped dose is deleted here', () async {
      final (p, ids) = await seedThree();

      final dropped = await DoseLogLocalDatasource().dropPendingByPrescription(
        p,
        pushable: false,
      );

      expect(dropped, 3);
      for (final id in ids) {
        expect(await maybeRow(id), isNull, reason: id);
      }
    });

    test('a kept id and a dose that is not pending stay', () async {
      final (p, ids) = await seedThree();
      final db = await AppDatabase.instance.database;
      final taken = await seedDoseLog(
        db,
        p,
        DateTime(2026, 3, 1, 20),
        status: 'taken',
      );

      final dropped = await DoseLogLocalDatasource().dropPendingByPrescription(
        p,
        keepIds: {ids[0]},
      );

      expect(dropped, 2);
      expect((await maybeRow(ids[0]))!['sync_status'], SyncStatus.synced);
      expect((await maybeRow(taken))!['sync_status'], SyncStatus.synced);
    });
  });

  group('a time correction', () {
    test('moves only a synced pending dose nobody touched, as an automatic '
        'change to push', () async {
      final db = await AppDatabase.instance.database;
      final p = (await seedPrescription(db)).prescriptionId;
      final slot = DateTime(2026, 3, 1, 16);
      final at18 = DateTime(2026, 3, 1, 18);
      final untouched = await seedDoseLog(db, p, at18, id: 'untouched');
      final automatic = await seedDoseLog(db, p, at18, id: 'automatic');
      final person = await seedDoseLog(db, p, at18, id: 'person');
      final waiting = await seedDoseLog(db, p, at18, id: 'waiting');
      final taken = await seedDoseLog(
        db,
        p,
        at18,
        id: 'taken',
        status: 'taken',
      );
      // Naive 1970 text, as an older backup may hold it, is automatic too.
      await db.update(
        'dose_logs',
        {'edited_at': '1970-01-01T01:00:00.000'},
        where: 'id = ?',
        whereArgs: [automatic],
      );
      await db.update(
        'dose_logs',
        {'edited_at': '2026-02-27T10:00:00.000Z'},
        where: 'id = ?',
        whereArgs: [person],
      );
      await db.update(
        'dose_logs',
        {'sync_status': SyncStatus.pendingUpdate},
        where: 'id = ?',
        whereArgs: [waiting],
      );

      final moved = await DoseLogLocalDatasource().correctScheduledTimes({
        for (final id in [untouched, automatic, person, waiting, taken, 'none'])
          id: slot,
      });

      expect(moved, 2);
      for (final id in [untouched, automatic]) {
        final r = await row(id);
        expect(DateTime.parse(r['scheduled_time']! as String), slot);
        expect(
          [r['sync_status'], r['edited_at'], times(r)['scheduled_time']],
          [SyncStatus.pendingUpdate, '1970-01-01T00:00:00.000Z', auto],
          reason: id,
        );
      }
      for (final id in [person, waiting, taken]) {
        expect(
          DateTime.parse((await row(id))['scheduled_time']! as String),
          at18,
          reason: id,
        );
      }
    });
  });
}
