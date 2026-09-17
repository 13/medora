/// Medora - Prescription Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:sqflite/sqflite.dart';

class PrescriptionLocalDatasource {
  /// [now] is the clock for the stamps a local write sets.
  PrescriptionLocalDatasource({this._now = systemNow});

  final Now _now;

  Future<Database> get _db => AppDatabase.instance.database;

  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(
    String treatmentId,
  ) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      WHERE p.treatment_id = ? AND p.sync_status != ?
      ORDER BY p.start_time ASC
    ''',
      [treatmentId, SyncStatus.pendingDelete],
    );
    return rows.map(PrescriptionModel.fromLocalMap).toList();
  }

  /// The prescriptions that are running: active themselves, and not part of
  /// an ended treatment. Ending a treatment leaves its prescriptions' own
  /// state alone (nothing to push), so the treatment is checked here.
  Future<List<PrescriptionModel>> getActivePrescriptions() async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      LEFT JOIN treatments t ON p.treatment_id = t.id
      WHERE p.is_active = 1 AND p.sync_status != ?
        AND $_treatmentRunning
      ORDER BY p.start_time ASC
    ''',
      [SyncStatus.pendingDelete],
    );
    return rows.map(PrescriptionModel.fromLocalMap).toList();
  }

  /// A prescription whose treatment is gone counts as running, as in the
  /// dose queries.
  static const _treatmentRunning = '(t.id IS NULL OR t.is_active = 1)';

  /// Whether prescription [id] belongs to a treatment that has ended. Such a
  /// prescription gets no new doses until the treatment is active again.
  Future<bool> isInEndedTreatment(String id) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT 1 FROM prescriptions p
      LEFT JOIN treatments t ON p.treatment_id = t.id
      WHERE p.id = ? AND NOT $_treatmentRunning
      LIMIT 1
    ''',
      [id],
    );
    return rows.isNotEmpty;
  }

  Future<PrescriptionModel?> getPrescriptionById(String id) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      WHERE p.id = ?
    ''',
      [id],
    );
    if (rows.isEmpty) return null;
    return PrescriptionModel.fromLocalMap(rows.first);
  }

  Future<void> upsert(
    PrescriptionModel model, {
    required String syncStatus,
  }) async {
    final db = await _db;
    final at = _now();
    final row = rowOf(model, syncStatus, now: () => at);
    if (syncStatus == SyncStatus.synced) {
      await _store(db, model.id, row);
      return;
    }
    await db.transaction((txn) async {
      // A change made here: stamp the columns it changes.
      row['field_edited_at'] = fieldTimesAfterWrite(
        previous: await _stored(txn, model.id),
        after: row,
        wireOf: wireOf,
        at: editedAtOf(model.updatedAt ?? at, at),
      );
      await _store(txn, model.id, row);
    });
  }

  /// UPDATE first: an INSERT OR REPLACE (ConflictAlgorithm.replace) would
  /// delete the row first and cascade-delete its doses.
  Future<void> _store(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> row,
  ) async {
    final updated = await db.update(
      'prescriptions',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(
        'prescriptions',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'prescriptions',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The wire copy of the stored row [row] (what the edit times compare).
  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      PrescriptionModel.fromLocalMap(row).toJson();

  /// Marks the row for deletion: pending push plus a local tombstone stamp
  /// (spec §4.6). A row already deleted keeps its stamps.
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      'prescriptions',
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': now.toIso8601String(),
        'edited_at': editedAtText(now, now),
      },
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.pendingDelete],
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _db;
    await db.delete('prescriptions', where: 'id = ?', whereArgs: [id]);
  }

  /// The row's `sync_status`, or null when there is no such row.
  Future<String?> syncStatusOf(String id) async {
    final db = await _db;
    final rows = await db.query(
      'prescriptions',
      columns: ['sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first['sync_status'] as String?;
  }

  /// Pauses the prescription; false, and nothing changed, when it is
  /// missing or deleted.
  Future<bool> deactivate(String id) => _setActive(id, active: false);

  /// Resumes the prescription; false, and nothing changed, when it is
  /// missing or deleted.
  Future<bool> reactivate(String id) => _setActive(id, active: true);

  /// Stamped with [nextUpdatedAt], so the change looks newer than the row's
  /// current stamp to last-write-wins even when that stamp came from a
  /// server whose clock is ahead of this device's.
  ///
  /// A deleted (`pending_delete`) row is left alone: a pause must never
  /// bring a deleted prescription back.
  Future<bool> _setActive(String id, {required bool active}) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'prescriptions',
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.pendingDelete],
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final raw = row['updated_at'] as String?;
      final previous = raw == null ? null : DateTime.tryParse(raw);
      final now = _now();
      final stamp = nextUpdatedAt(previous, now);
      final change = {'is_active': active ? 1 : 0};
      await txn.update(
        'prescriptions',
        {
          ...change,
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': stamp.toIso8601String(),
          'edited_at': editedAtText(stamp, now),
          'field_edited_at': fieldTimesAfterWrite(
            previous: row,
            after: {...row, ...change},
            wireOf: wireOf,
            at: editedAtOf(stamp, now),
          ),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return true;
    });
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('prescriptions');
  }

  /// The row [m] is stored as. [now] stamps what the model leaves unset.
  static Map<String, dynamic> rowOf(
    PrescriptionModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    final row = m.toLocalMap();
    row['sync_status'] = syncStatus;
    row['created_at'] ??= at.toIso8601String();
    row['updated_at'] = (m.updatedAt ?? at).toIso8601String();
    // A change made here was made when it was stamped; a pulled row gets
    // the server's edit time from the sync cycle instead.
    if (syncStatus != SyncStatus.synced) {
      row['edited_at'] = editedAtText(m.updatedAt ?? at, at);
    }
    return row;
  }
}
