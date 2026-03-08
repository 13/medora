/// Medora - Prescription Local Datasource
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:sqflite/sqflite.dart';

class PrescriptionLocalDatasource {
  PrescriptionLocalDatasource();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(
      String treatmentId) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      WHERE p.treatment_id = ? AND p.sync_status != ?
      ORDER BY p.start_time ASC
    ''', [treatmentId, SyncStatus.pendingDelete]);
    return rows.map((r) => PrescriptionModel.fromLocalMap(r)).toList();
  }

  Future<List<PrescriptionModel>> getActivePrescriptions() async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      WHERE p.is_active = 1 AND p.sync_status != ?
      ORDER BY p.start_time ASC
    ''', [SyncStatus.pendingDelete]);
    return rows.map((r) => PrescriptionModel.fromLocalMap(r)).toList();
  }

  Future<PrescriptionModel?> getPrescriptionById(String id) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.*, m.name AS medication_name
      FROM prescriptions p
      LEFT JOIN medications m ON p.medication_id = m.id
      WHERE p.id = ?
    ''', [id]);
    if (rows.isEmpty) return null;
    return PrescriptionModel.fromLocalMap(rows.first);
  }

  Future<void> upsert(PrescriptionModel model,
      {required String syncStatus}) async {
    final db = await _db;
    final row = _toRow(model, syncStatus);
    // Use UPDATE-first to avoid DELETE+INSERT from ConflictAlgorithm.replace,
    // which would CASCADE-DELETE all dose_logs for this prescription.
    final updated = await db.update('prescriptions', row,
        where: 'id = ?', whereArgs: [model.id]);
    if (updated == 0) {
      await db.insert('prescriptions', row,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> markDeleted(String id) async {
    final db = await _db;
    await db.update(
        'prescriptions', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> hardDelete(String id) async {
    final db = await _db;
    await db.delete('prescriptions', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deactivate(String id) async {
    final db = await _db;
    await db.update(
        'prescriptions',
        {
          'is_active': 0,
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<void> reactivate(String id) async {
    final db = await _db;
    await db.update(
        'prescriptions',
        {
          'is_active': 1,
          'sync_status': SyncStatus.pendingUpdate,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query('prescriptions',
        where: 'sync_status != ?', whereArgs: [SyncStatus.synced]);
  }

  Future<void> markSynced(String id) async {
    final db = await _db;
    await db.update('prescriptions', {'sync_status': SyncStatus.synced},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('prescriptions');
  }


  Map<String, dynamic> _toRow(PrescriptionModel m, String syncStatus) {
    final row = m.toLocalMap();
    row['sync_status'] = syncStatus;
    row['created_at'] ??= DateTime.now().toIso8601String();
    return row;
  }
}

