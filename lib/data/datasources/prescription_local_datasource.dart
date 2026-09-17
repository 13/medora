/// Medora - Prescription Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
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
    final row = rowOf(model, syncStatus, now: _now);
    // Use UPDATE-first to avoid DELETE+INSERT from ConflictAlgorithm.replace,
    // which would CASCADE-DELETE all dose_logs for this prescription.
    final updated = await db.update(
      'prescriptions',
      row,
      where: 'id = ?',
      whereArgs: [model.id],
    );
    if (updated == 0) {
      await db.insert(
        'prescriptions',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

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
        columns: ['updated_at'],
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.pendingDelete],
      );
      if (rows.isEmpty) return false;
      final raw = rows.first['updated_at'] as String?;
      final previous = raw == null ? null : DateTime.tryParse(raw);
      final now = _now();
      final stamp = nextUpdatedAt(previous, now);
      await txn.update(
        'prescriptions',
        {
          'is_active': active ? 1 : 0,
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': stamp.toIso8601String(),
          'edited_at': editedAtText(stamp, now),
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
