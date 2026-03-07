/// Medora - Dose Log Local Datasource
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:sqflite/sqflite.dart';

class DoseLogLocalDatasource {
  DoseLogLocalDatasource();

  Future<Database> get _db => AppDatabase.instance.database;

  /// Shared JOIN query for fetching dose logs with medication info.
  static const _joinQuery = '''
    SELECT d.*,
           m.name AS medication_name,
           m.patient_tags AS patient_tags,
           m.quantity_unit AS medication_unit,
           p.dosage AS dosage,
           p.dosage_amount AS dosage_amount,
           p.dosage_unit AS dosage_unit,
           p.notes AS prescription_notes,
           t.name AS treatment_name
    FROM dose_logs d
    LEFT JOIN prescriptions p ON d.prescription_id = p.id
    LEFT JOIN treatments t ON p.treatment_id = t.id
    LEFT JOIN medications m ON p.medication_id = m.id
  ''';

  /// Shared JOIN query filtered to only active treatments + non-archived medications.
  static const _activeJoinQuery = '''
    SELECT d.*,
           m.name AS medication_name,
           m.patient_tags AS patient_tags,
           m.quantity_unit AS medication_unit,
           p.dosage AS dosage,
           p.dosage_amount AS dosage_amount,
           p.dosage_unit AS dosage_unit,
           p.notes AS prescription_notes,
           t.name AS treatment_name
    FROM dose_logs d
    LEFT JOIN prescriptions p ON d.prescription_id = p.id
    LEFT JOIN treatments t ON p.treatment_id = t.id
    LEFT JOIN medications m ON p.medication_id = m.id
  ''';

  Future<List<DoseLogModel>> getDoseLogsByPrescription(
      String prescriptionId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE d.prescription_id = ? AND d.sync_status != ? ORDER BY d.scheduled_time ASC',
      [prescriptionId, SyncStatus.pendingDelete],
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<DoseLogModel>> getTodaysDoseLogs() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    final db = await _db;
    // Only show doses for active prescriptions in active treatments with non-archived medications
    final rows = await db.rawQuery(
      '''$_activeJoinQuery
        WHERE d.scheduled_time >= ? AND d.scheduled_time < ?
        AND d.sync_status != ?
        AND (p.is_active IS NULL OR p.is_active = 1)
        AND (t.id IS NULL OR t.is_active = 1)
        AND (m.id IS NULL OR (m.is_archived IS NULL OR m.is_archived = 0))
        ORDER BY d.scheduled_time ASC''',
      [
        start.toIso8601String(),
        end.toIso8601String(),
        SyncStatus.pendingDelete,
      ],
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<DoseLogModel>> getDoseLogsByDateRange(
      DateTime start, DateTime end) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE d.scheduled_time >= ? AND d.scheduled_time < ? AND d.sync_status != ? ORDER BY d.scheduled_time ASC',
      [start.toIso8601String(), end.toIso8601String(), SyncStatus.pendingDelete],
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> upsert(DoseLogModel model, {required String syncStatus}) async {
    final db = await _db;
    await db.insert('dose_logs', _toRow(model, syncStatus),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertBatch(List<DoseLogModel> models,
      {required String syncStatus}) async {
    final db = await _db;
    final batch = db.batch();
    for (final model in models) {
      batch.insert('dose_logs', _toRow(model, syncStatus),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateStatus(String id, String status,
      {DateTime? takenTime, required String syncStatus}) async {
    final db = await _db;
    final updates = <String, dynamic>{
      'status': status,
      'sync_status': syncStatus,
    };
    if (takenTime != null) {
      updates['taken_time'] = takenTime.toIso8601String();
    }
    await db
        .update('dose_logs', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query('dose_logs',
        where: 'sync_status != ?', whereArgs: [SyncStatus.synced]);
  }

  Future<void> markSynced(String id) async {
    final db = await _db;
    await db.update('dose_logs', {'sync_status': SyncStatus.synced},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('dose_logs');
  }

  DoseLogModel _fromRow(Map<String, dynamic> row) {
    return DoseLogModel(
      id: row['id'] as String,
      prescriptionId: row['prescription_id'] as String,
      scheduledTime: DateTime.parse(row['scheduled_time'] as String),
      takenTime: row['taken_time'] != null
          ? DateTime.tryParse(row['taken_time'] as String)
          : null,
      status:
          DoseStatus.fromString(row['status'] as String? ?? 'pending'),
      notes: row['notes'] as String?,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)
          : null,
      medicationName: row['medication_name'] as String?,
      dosage: row['dosage'] as String?,
      dosageAmount: (row['dosage_amount'] as num?)?.toDouble(),
      dosageUnit: row['dosage_unit'] as String?,
      medicationUnit: row['medication_unit'] as String?,
      patientTags: MedicationModel.parseTags(row['patient_tags']),
      treatmentName: row['treatment_name'] as String?,
      prescriptionNotes: row['prescription_notes'] as String?,
    );
  }

  Map<String, dynamic> _toRow(DoseLogModel m, String syncStatus) {
    return {
      'id': m.id,
      'prescription_id': m.prescriptionId,
      'scheduled_time': m.scheduledTime.toIso8601String(),
      'taken_time': m.takenTime?.toIso8601String(),
      'status': m.status.name,
      'notes': m.notes,
      'created_at':
          m.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'sync_status': syncStatus,
    };
  }
}

