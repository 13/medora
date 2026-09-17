/// Medora - Dose Log Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:sqflite/sqflite.dart';

class DoseLogLocalDatasource {
  /// [now] is the clock for the stamps a local write sets.
  DoseLogLocalDatasource({this._now = systemNow});

  final Now _now;

  Future<Database> get _db => AppDatabase.instance.database;

  /// Shared JOIN query for fetching dose logs with medication and treatment info.
  /// Uses patient_tags from treatments instead of medications.
  static const _joinQuery = '''
    SELECT d.*,
           m.name AS medication_name,
           t.patient_tags AS patient_tags,
           m.quantity_unit AS medication_unit,
           p.dosage AS dosage,
           p.dosage_amount AS dosage_amount,
           p.dosage_unit AS dosage_unit,
           p.notes AS prescription_notes,
           p.schedule_type AS schedule_type,
           t.name AS treatment_name
    FROM dose_logs d
    LEFT JOIN prescriptions p ON d.prescription_id = p.id
    LEFT JOIN treatments t ON p.treatment_id = t.id
    LEFT JOIN medications m ON p.medication_id = m.id
  ''';

  Future<List<DoseLogModel>> getDoseLogsByPrescription(
    String prescriptionId,
  ) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE d.prescription_id = ? AND d.sync_status != ? ORDER BY d.scheduled_time ASC',
      [prescriptionId, SyncStatus.pendingDelete],
    );
    return rows.map(_fromRow).toList();
  }

  /// Every dose logged under [treatmentId]'s prescriptions, oldest first,
  /// whatever its status or its prescription's state; a deleted dose is left
  /// out.
  ///
  /// This is the episode's real intake record: it is derived from the dose
  /// history the user already produces day by day, never retyped.
  Future<List<DoseLogModel>> getDoseLogsByTreatment(String treatmentId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE p.treatment_id = ? AND d.sync_status != ? '
      'ORDER BY d.scheduled_time ASC',
      [treatmentId, SyncStatus.pendingDelete],
    );
    return _dedupeById(rows).map(_fromRow).toList();
  }

  /// One dose log with its joined display fields, or null. A deleted dose
  /// (a tombstone waiting to be pushed) is not returned, so it can be
  /// neither changed nor deleted again.
  Future<DoseLogModel?> getDoseLogById(String id) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '$_joinQuery WHERE d.id = ? AND d.sync_status != ? LIMIT 1',
      [id, SyncStatus.pendingDelete],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Shared WHERE fragment: non-pending rows are always included (they are
  /// historical facts); pending rows only when their prescription/treatment
  /// is active, their medication is not archived (or absent) and their
  /// prescription has a schedule ([_scheduled]).
  static const _pendingOnlyIfActive =
      '''(d.status != 'pending' OR ((p.is_active IS NULL OR p.is_active = 1) AND (t.id IS NULL OR t.is_active = 1) AND (m.id IS NULL OR (m.is_archived IS NULL OR m.is_archived = 0)) AND $_scheduled))''';

  /// An as-needed prescription has no schedule, so a pending dose of one is
  /// never due: this app never creates one, but an older build that reads
  /// 'as_needed' as a fixed interval generates them and syncs them over, and
  /// a prescription switched to as-needed elsewhere leaves its old ones.
  /// Such a dose is neither listed, nor reminded, nor marked missed.
  static const _scheduled =
      '''(p.schedule_type IS NULL OR p.schedule_type != 'as_needed')''';

  Future<List<DoseLogModel>> getTodaysDoseLogs() async {
    final now = _now();
    final start = DateTime(now.year, now.month, now.day);
    final end = DateTime(now.year, now.month, now.day + 1);
    final db = await _db;
    // Show ALL non-pending doses (taken/skipped/missed) regardless of
    // treatment/prescription/medication status — they are historical facts.
    // Only filter PENDING doses to active prescriptions/treatments/medications.
    final rows = await db.rawQuery(
      '''$_joinQuery
        WHERE d.scheduled_time >= ? AND d.scheduled_time < ?
        AND d.sync_status != ?
        AND $_pendingOnlyIfActive
        ORDER BY d.scheduled_time ASC''',
      [
        start.toIso8601String(),
        end.toIso8601String(),
        SyncStatus.pendingDelete,
      ],
    );
    return _dedupeById(rows).map(_fromRow).toList();
  }

  Future<List<DoseLogModel>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db;
    // Apply the same rule as [getTodaysDoseLogs]: non-pending rows are
    // always included; pending rows only for active prescriptions/
    // treatments and non-archived medications.
    final rows = await db.rawQuery(
      '''$_joinQuery
        WHERE d.scheduled_time >= ? AND d.scheduled_time < ?
        AND d.sync_status != ?
        AND $_pendingOnlyIfActive
        ORDER BY d.scheduled_time ASC''',
      [
        start.toIso8601String(),
        end.toIso8601String(),
        SyncStatus.pendingDelete,
      ],
    );
    return _dedupeById(rows).map(_fromRow).toList();
  }

  /// Pending doses with scheduled_time in [start, end), for active scheduled
  /// prescriptions, active treatments and non-archived medications, earliest
  /// first.
  Future<List<DoseLogModel>> getPendingBetween(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''$_joinQuery
        WHERE d.status = 'pending'
        AND d.scheduled_time >= ? AND d.scheduled_time < ?
        AND d.sync_status != ?
        AND (p.is_active IS NULL OR p.is_active = 1)
        AND (t.id IS NULL OR t.is_active = 1)
        AND (m.id IS NULL OR (m.is_archived IS NULL OR m.is_archived = 0))
        AND $_scheduled
        ORDER BY d.scheduled_time ASC''',
      [
        start.toIso8601String(),
        end.toIso8601String(),
        SyncStatus.pendingDelete,
      ],
    );
    return _dedupeById(rows).map(_fromRow).toList();
  }

  /// Deduplicate rows by dose log ID to prevent showing/scheduling the same
  /// dose multiple times (a LEFT JOIN can fan out a row when joined data is
  /// duplicated upstream).
  List<Map<String, dynamic>> _dedupeById(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = row['id'] as String;
      if (!seen.contains(id)) {
        seen.add(id);
        unique.add(row);
      }
    }
    return unique;
  }

  Future<void> upsert(DoseLogModel model, {required String syncStatus}) async {
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

  /// UPDATE first, never DELETE + INSERT.
  Future<void> _store(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> row,
  ) async {
    final updated = await db.update(
      'dose_logs',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(
        'dose_logs',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query('dose_logs', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The wire copy of the stored row [row] (what the edit times compare).
  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      DoseLogModel.fromLocalMap(row).toJson();

  /// Inserts [models] in one transaction, leaving any row that already has
  /// one of their ids untouched: a generated dose never replaces a dose
  /// already stored, whatever its time or status.
  Future<void> insertBatchIfAbsent(
    List<DoseLogModel> models, {
    required String syncStatus,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final model in models) {
        batch.insert(
          'dose_logs',
          rowOf(model, syncStatus, now: _now),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Change a dose's status. Pass [clearTakenTime] to null out `taken_time`
  /// (undo). Always moves `updated_at`, so a push of the row in flight
  /// notices the change.
  Future<void> updateStatus(
    String id,
    String status, {
    DateTime? takenTime,
    bool clearTakenTime = false,
    required String syncStatus,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      // Never stamp a time at or before the row's current one: see
      // [nextUpdatedAt]. A dose toggled twice in the same millisecond, or on
      // a device whose clock just stepped back, must still look like the
      // newer write to last-write-wins sync.
      final rows = await txn.query(
        'dose_logs',
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.pendingDelete],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final previousRaw = row['updated_at'] as String?;
      final previous = previousRaw == null
          ? null
          : DateTime.tryParse(previousRaw);
      final now = _now();
      final stamp = nextUpdatedAt(previous, now);
      final change = <String, Object?>{'status': status};
      if (clearTakenTime) {
        change['taken_time'] = null;
      } else if (takenTime != null) {
        change['taken_time'] = takenTime.toIso8601String();
      }
      await txn.update(
        'dose_logs',
        {
          ...change,
          'sync_status': syncStatus,
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
    });
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query(
      'dose_logs',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.synced],
    );
  }

  /// Marks the row for deletion: pending push plus a local tombstone stamp
  /// (spec §4.6).
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      'dose_logs',
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': now.toIso8601String(),
        'edited_at': editedAtText(now, now),
        // A person's delete is never guarded, even if an old automatic
        // guard was left on the row.
        'delete_guard': null,
      },
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.pendingDelete],
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _db;
    await db.delete('dose_logs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('dose_logs');
  }

  /// Drops the pending doses of [prescriptionId], except the ones in
  /// [keepIds]; taken, skipped and missed doses are never touched. Returns
  /// how many were dropped.
  ///
  /// A dose no server has seen (no known server version and no write
  /// attempt: a generated dose not sent yet) is deleted here and now, and
  /// so is every dose without sync ([pushable] false, local-only mode).
  /// Every other one becomes a guarded delete (`delete_guard =
  /// 'if_pending'`, the automatic edit time): the server deletes it only
  /// while it is still pending there, so a dose taken on another device
  /// meanwhile survives and comes back here.
  Future<int> dropPendingByPrescription(
    String prescriptionId, {
    Set<String> keepIds = const {},
    bool pushable = true,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'dose_logs',
        where:
            "prescription_id = ? AND status = 'pending' AND sync_status != ?",
        whereArgs: [prescriptionId, SyncStatus.pendingDelete],
      );
      final now = _now();
      var dropped = 0;
      for (final row in rows) {
        final id = row['id']! as String;
        if (keepIds.contains(id)) continue;
        dropped++;
        final unseen =
            row['sync_version'] == null && row['sync_write_id'] == null;
        if (!pushable || unseen) {
          await txn.delete('dose_logs', where: 'id = ?', whereArgs: [id]);
          continue;
        }
        await txn.update(
          'dose_logs',
          {
            'sync_status': SyncStatus.pendingDelete,
            'delete_guard': 'if_pending',
            'deleted_at': now.toIso8601String(),
            // The app's own change. A delete changes no column that has a
            // time, so the map is only filled: the columns keep the time
            // the row had before its own time became the automatic one.
            'edited_at': _automaticEditedAt,
            'field_edited_at': _automaticTimes(row, const {}),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      return dropped;
    });
  }

  /// Mark pending doses scheduled before [cutoff] as missed. Returns how
  /// many changed, and how many of those have to be pushed (all of them,
  /// unless [pushable] is false). Scoped to doses whose prescription is
  /// active and scheduled, whose treatment is active (or absent), and whose
  /// medication is not archived (or absent) — the same predicates
  /// [getPendingBetween] uses.
  ///
  /// "Missed" is the app's own conclusion, not something the user did, so
  /// it carries the automatic edit time, on the row and on `status`:
  /// pushed, it loses to any change a person made to the same dose on
  /// another device, and the server keeps `updated_at`, so older builds
  /// never count it as newer.
  /// - a `synced` row becomes `pending_update`; its push is conditional on
  ///   the version this device holds;
  /// - a `pending_create` row keeps its status and goes out with the insert;
  /// - a row with a change still waiting to be pushed (`pending_update`, for
  ///   example an undo made offline) is left alone: the push would send the
  ///   sweep's "missed" in the same write as the person's change. It is
  ///   swept once synced.
  ///
  /// `updated_at` moves just past its own stamp ([automaticUpdatedAt]), so
  /// a push in flight notices the row changed.
  ///
  /// Without sync ([pushable] false, local-only mode) nothing is ever
  /// pushed, so a dose taken and then undone (left `pending_update`) is
  /// swept too, and no `sync_status` changes.
  Future<({int changed, int unpushed})> markOverduePendingAsMissed(
    DateTime cutoff, {
    bool pushable = true,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'dose_logs',
        where:
            '''status = 'pending'
           AND scheduled_time < ?
           AND sync_status NOT IN (?, ?)
           AND prescription_id IN (
             SELECT p.id FROM prescriptions p
             LEFT JOIN treatments t ON p.treatment_id = t.id
             LEFT JOIN medications m ON p.medication_id = m.id
             WHERE p.is_active = 1
               AND (t.id IS NULL OR t.is_active = 1)
               AND (m.id IS NULL OR m.is_archived IS NULL OR m.is_archived = 0)
               AND $_scheduled
           )''',
        whereArgs: [
          cutoff.toIso8601String(),
          SyncStatus.pendingDelete,
          pushable ? SyncStatus.pendingUpdate : SyncStatus.pendingDelete,
        ],
      );
      for (final row in rows) {
        const change = {'status': 'missed'};
        await txn.update(
          'dose_logs',
          {
            ...change,
            ..._automaticStamps(row, change),
            if (pushable && row['sync_status'] == SyncStatus.synced)
              'sync_status': SyncStatus.pendingUpdate,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      return (changed: rows.length, unpushed: pushable ? rows.length : 0);
    });
  }

  /// Moves each dose in [slotTimes] (dose id → its slot's time) to that
  /// time, when it is still a pending dose nobody touched: `synced`, and
  /// with no edit time or the automatic one. Older builds stored some slots
  /// hours off under the slot's own id. The change is the app's own (the
  /// automatic edit time, on the row and on `scheduled_time`), so it never
  /// beats a change a person made elsewhere; it goes out as a conditional
  /// push. Returns how many moved.
  Future<int> correctScheduledTimes(Map<String, DateTime> slotTimes) async {
    if (slotTimes.isEmpty) return 0;
    final db = await _db;
    return db.transaction((txn) async {
      var moved = 0;
      for (final MapEntry(key: id, value: time) in slotTimes.entries) {
        final rows = await txn.query(
          'dose_logs',
          where: "id = ? AND status = 'pending' AND sync_status = ?",
          whereArgs: [id, SyncStatus.synced],
        );
        if (rows.isEmpty) continue;
        final row = rows.first;
        // Parsed as an instant, never compared as text: older rows hold
        // local wall-clock text.
        final edited = row['edited_at'] as String?;
        final editedAt = edited == null ? null : DateTime.tryParse(edited);
        if (editedAt != null && !FieldTime(editedAt).automatic) continue;
        final change = {'scheduled_time': time.toIso8601String()};
        moved += await txn.update(
          'dose_logs',
          {
            ...change,
            ..._automaticStamps(row, change),
            'sync_status': SyncStatus.pendingUpdate,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      return moved;
    });
  }

  /// The edit time of a change the app made on its own.
  static final String _automaticEditedAt = FieldTime.automaticChange.at
      .toIso8601String();

  /// The stamps of a change the app made on its own to [row]: `updated_at`
  /// just past its own ([automaticUpdatedAt]), the automatic edit time, and
  /// the columns of [change] marked automatic.
  static Map<String, Object?> _automaticStamps(
    Map<String, Object?> row,
    Map<String, Object?> change,
  ) {
    final raw = row['updated_at'] as String?;
    final previous = raw == null ? null : DateTime.tryParse(raw);
    return {
      'updated_at': automaticUpdatedAt(previous).toIso8601String(),
      'edited_at': _automaticEditedAt,
      'field_edited_at': _automaticTimes(row, change),
    };
  }

  /// The `field_edited_at` of [row] after the app changed [change] on its
  /// own.
  static String? _automaticTimes(
    Map<String, Object?> row,
    Map<String, Object?> change,
  ) => fieldTimesAfterWrite(
    previous: row,
    after: {...row, ...change},
    wireOf: wireOf,
    at: FieldTime.automaticChange.at,
  );

  DoseLogModel _fromRow(Map<String, dynamic> row) {
    return DoseLogModel(
      id: row['id'] as String,
      prescriptionId: row['prescription_id'] as String,
      scheduledTime: DateTime.parse(row['scheduled_time'] as String).toLocal(),
      takenTime: row['taken_time'] != null
          ? DateTime.tryParse(row['taken_time'] as String)?.toLocal()
          : null,
      status: DoseStatus.fromString(row['status'] as String? ?? 'pending'),
      notes: row['notes'] as String?,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)?.toLocal()
          : null,
      updatedAt: row['updated_at'] != null
          ? DateTime.tryParse(row['updated_at'] as String)?.toLocal()
          : null,
      medicationName: row['medication_name'] as String?,
      dosage: row['dosage'] as String?,
      dosageAmount: (row['dosage_amount'] as num?)?.toDouble(),
      dosageUnit: row['dosage_unit'] as String?,
      medicationUnit: row['medication_unit'] as String?,
      patientTags: MedicationModel.parseTags(row['patient_tags']),
      treatmentName: row['treatment_name'] as String?,
      prescriptionNotes: row['prescription_notes'] as String?,
      asNeeded: row['schedule_type'] == 'as_needed',
    );
  }

  /// The row [m] is stored as. [now] stamps what the model leaves unset.
  static Map<String, dynamic> rowOf(
    DoseLogModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      'id': m.id,
      'prescription_id': m.prescriptionId,
      'scheduled_time': m.scheduledTime.toIso8601String(),
      'taken_time': m.takenTime?.toIso8601String(),
      'status': m.status.name,
      'notes': m.notes,
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
