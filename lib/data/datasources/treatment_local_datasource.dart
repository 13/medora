/// Medora - Treatment Local Datasource
library;

import 'dart:convert';

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:sqflite/sqflite.dart';

class TreatmentLocalDatasource {
  /// [now] is the clock for the stamps a local write sets.
  TreatmentLocalDatasource({this._now = systemNow});

  final Now _now;

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
    final rows = await db.query('treatments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> upsert(
    TreatmentModel model, {
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
  /// delete the row first and cascade-delete its prescriptions and doses.
  Future<void> _store(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> row,
  ) async {
    final updated = await db.update(
      'treatments',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(
        'treatments',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query('treatments', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The wire copy of the stored row [row] (what the edit times compare).
  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      TreatmentModel.fromLocalMap(row).toJson();

  /// Marks the row for deletion: pending push plus a local tombstone stamp
  /// (spec §4.6). A row already deleted keeps its stamps.
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      'treatments',
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
    await db.delete('treatments', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query(
      'treatments',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.synced],
    );
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
        row['patient_tags'] ?? row['patient_name'],
      ),
      symptomTags: MedicationModel.parseTags(
        row['symptom_tags'] ?? row['symptoms'],
      ),
      startDate: DateTime.parse(row['start_date'] as String),
      endDate: row['end_date'] != null
          ? DateTime.tryParse(row['end_date'] as String)
          : null,
      isActive: (row['is_active'] as int? ?? 1) == 1,
      notes: row['notes'] as String?,
      sickLeaveFrom: row['sick_leave_from'] != null
          ? DateTime.tryParse(row['sick_leave_from'] as String)
          : null,
      sickLeaveTo: row['sick_leave_to'] != null
          ? DateTime.tryParse(row['sick_leave_to'] as String)
          : null,
      sickLeaveRef: row['sick_leave_ref'] as String?,
      doctor: row['doctor'] as String?,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)
          : null,
      updatedAt: row['updated_at'] != null
          ? DateTime.tryParse(row['updated_at'] as String)
          : null,
      deletedAt: row['deleted_at'] != null
          ? DateTime.tryParse(row['deleted_at'] as String)
          : null,
    );
  }

  /// The row [m] is stored as. [now] stamps what the model leaves unset.
  static Map<String, dynamic> rowOf(
    TreatmentModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
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
      'sick_leave_from': m.sickLeaveFrom?.toIso8601String().split('T').first,
      'sick_leave_to': m.sickLeaveTo?.toIso8601String().split('T').first,
      'sick_leave_ref': m.sickLeaveRef,
      'doctor': m.doctor,
      'created_at': (m.createdAt ?? at).toIso8601String(),
      'updated_at': (m.updatedAt ?? at).toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      'sync_status': syncStatus,
      // A change made here was made when it was stamped; a pulled row gets
      // the server's edit time from the sync cycle instead.
      if (syncStatus != SyncStatus.synced)
        'edited_at': editedAtText(m.updatedAt ?? at, at),
    };
  }
}
