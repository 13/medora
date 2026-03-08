/// Medora - Treatment Local Datasource
library;

import 'dart:convert';

import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:sqflite/sqflite.dart';

class TreatmentLocalDatasource {
  TreatmentLocalDatasource();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<List<TreatmentModel>> getTreatments() async {
    final db = await _db;
    final rows = await db.query(
      'treatments',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'start_date DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<TreatmentModel>> getActiveTreatments() async {
    final db = await _db;
    final rows = await db.query(
      'treatments',
      where: 'is_active = 1 AND sync_status != ?',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'start_date DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<TreatmentModel?> getTreatmentById(String id) async {
    final db = await _db;
    final rows =
        await db.query('treatments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> upsert(TreatmentModel model,
      {required String syncStatus}) async {
    final db = await _db;
    final row = _toRow(model, syncStatus);
    // Use UPDATE-first to avoid DELETE+INSERT from ConflictAlgorithm.replace,
    // which would CASCADE-DELETE prescriptions and dose_logs.
    final updated = await db.update('treatments', row,
        where: 'id = ?', whereArgs: [model.id]);
    if (updated == 0) {
      await db.insert('treatments', row,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> markDeleted(String id) async {
    final db = await _db;
    await db.update('treatments', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> hardDelete(String id) async {
    final db = await _db;
    await db.delete('treatments', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query('treatments',
        where: 'sync_status != ?', whereArgs: [SyncStatus.synced]);
  }

  Future<void> markSynced(String id) async {
    final db = await _db;
    await db.update('treatments', {'sync_status': SyncStatus.synced},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('treatments');
  }

  TreatmentModel _fromRow(Map<String, dynamic> row) {
    return TreatmentModel(
      id: row['id'] as String,
      userId: row['user_id'] as String?,
      name: row['name'] as String,
      patientTags: MedicationModel.parseTags(
          row['patient_tags'] ?? row['patient_name']),
      symptomTags: MedicationModel.parseTags(
          row['symptom_tags'] ?? row['symptoms']),
      startDate: DateTime.parse(row['start_date'] as String),
      endDate: row['end_date'] != null
          ? DateTime.tryParse(row['end_date'] as String)
          : null,
      isActive: (row['is_active'] as int? ?? 1) == 1,
      notes: row['notes'] as String?,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)
          : null,
      updatedAt: row['updated_at'] != null
          ? DateTime.tryParse(row['updated_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> _toRow(TreatmentModel m, String syncStatus) {
    return {
      'id': m.id,
      'user_id': m.userId,
      'name': m.name,
      'patient_tags': jsonEncode(m.patientTags),
      'symptom_tags': jsonEncode(m.symptomTags),
      'start_date': m.startDate.toIso8601String().split('T').first,
      'end_date': m.endDate?.toIso8601String().split('T').first,
      'is_active': m.isActive ? 1 : 0,
      'notes': m.notes,
      'created_at':
          m.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'sync_status': syncStatus,
    };
  }
}

