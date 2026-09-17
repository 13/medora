/// Medora - Medication Local Datasource
library;

import 'dart:convert';

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:sqflite/sqflite.dart';

/// When a stock change made here waits in the stock outbox, to go out as a
/// change through `apply_stock_change`.
enum StockQueueing {
  /// Cloud mode: every change waits. One for a medication the server has
  /// not seen yet rides with its insert instead (see `TableSync`).
  always,

  /// Local-only mode: only a change to a medication the server has seen (a
  /// known server version) waits. A device that left cloud mode and kept
  /// its data then still sends its doses when it signs back in; one that
  /// never synced has no server to send them to.
  ifKnownToServer;

  /// Whether a change to the stored medication [row] waits.
  bool queues(Map<String, Object?> row) => switch (this) {
    always => true,
    ifKnownToServer => row['sync_version'] != null,
  };
}

class MedicationLocalDatasource {
  /// [now] is the clock for the stamps a local write sets.
  MedicationLocalDatasource({this._now = systemNow});

  final Now _now;

  Future<Database> get _db => AppDatabase.instance.database;

  /// Get all medications (including archived, excluding deleted).
  Future<List<MedicationModel>> getMedications() async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Get only archived medications.
  Future<List<MedicationModel>> getArchivedMedications() async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where: 'sync_status != ? AND is_archived = 1',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Archive a medication. False when it is missing or deleted.
  Future<bool> archiveMedication(String id) => _setArchived(id, archived: true);

  /// Unarchive a medication. False when it is missing or deleted.
  Future<bool> unarchiveMedication(String id) =>
      _setArchived(id, archived: false);

  /// Returns false, and changes nothing, when the medication is missing or
  /// deleted (see [_editRow]).
  Future<bool> _setArchived(String id, {required bool archived}) =>
      _editRow(id, (_) => {'is_archived': archived ? 1 : 0});

  /// Adds [delta] to the stock, never going below zero or above
  /// [maxStock]. Returns the stored row, or null (and changes nothing) when
  /// the medication is missing or deleted. Only the quantity is written, so
  /// no other column can be lost on the way.
  ///
  /// A stock change is not a row edit: it goes out as a change, never as
  /// the new total (design section 4.8). With [opId] it waits in the stock
  /// outbox, written in the same transaction, when [queueing] says so; the
  /// row keeps its status and stamps, so a change made while the row's push
  /// is in flight never makes that push look stale. A change that is not
  /// queued stamps `updated_at` and `edited_at` (a backup merge compares
  /// them) and fills the column times as every local write does, still
  /// leaving the status alone.
  Future<MedicationModel?> adjustQuantity(
    String id,
    int delta, {
    String? opId,
    StockQueueing queueing = StockQueueing.always,
  }) async {
    final db = await _db;
    final changed = await db.transaction((txn) async {
      final row = await _stored(txn, id);
      if (row == null) return false;
      if (row['sync_status'] == SyncStatus.pendingDelete) return false;
      final now = _now();
      final change = StockOp(
        opId: opId ?? '',
        medicationId: id,
        delta: delta,
        createdAt: now,
      );
      final values = <String, Object?>{
        // By the server's rule, as the change will apply there.
        'quantity': applyStockOps(row['quantity'] as int? ?? 0, [change]),
      };
      if (opId != null && queueing.queues(row)) {
        await StockOutboxLocalDatasource.enqueue(txn, change);
      } else {
        final raw = row['updated_at'] as String?;
        final stamp = nextUpdatedAt(
          raw == null ? null : DateTime.tryParse(raw),
          now,
        );
        values['updated_at'] = stamp.toIso8601String();
        values['edited_at'] = editedAtText(stamp, now);
        // The row time moves: an empty map is filled with the old one, so
        // no other column looks changed now (the stock has no entry).
        values['field_edited_at'] = fieldTimesAfterWrite(
          previous: row,
          after: {...row, ...values},
          wireOf: wireOf,
          at: editedAtOf(stamp, now),
        );
      }
      await txn.update('medications', values, where: 'id = ?', whereArgs: [id]);
      return true;
    });
    return changed ? getMedicationById(id) : null;
  }

  /// The row's `sync_status`, or null when there is no such row.
  Future<String?> syncStatusOf(String id) async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      columns: ['sync_status'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first['sync_status'] as String?;
  }

  /// The `sync_status` a local edit leaves on a row whose status is
  /// [current]: a row the server has never seen stays a create.
  static String editedSyncStatus(String? current) =>
      current == SyncStatus.pendingCreate
      ? SyncStatus.pendingCreate
      : SyncStatus.pendingUpdate;

  /// Writes the columns [changes] computes from the current row, plus the
  /// bookkeeping every local edit needs, in one transaction:
  /// - `updated_at` is stamped with [nextUpdatedAt], so the change looks
  ///   newer than the row's current stamp to last-write-wins even when that
  ///   stamp came from a server whose clock is ahead of this device's, and
  ///   `edited_at` records the same instant in UTC, never later than now
  ///   ([editedAtText]);
  /// - `field_edited_at` stamps the same instant on exactly the columns
  ///   [changes] changes ([fieldTimesAfterWrite]);
  /// - `sync_status` follows [editedSyncStatus].
  ///
  /// A missing or deleted (`pending_delete`) row is left alone and false is
  /// returned: an edit must never bring a deleted medication back.
  Future<bool> _editRow(
    String id,
    Map<String, Object?> Function(Map<String, Object?> row) changes,
  ) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'medications',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final status = row['sync_status'] as String?;
      if (status == SyncStatus.pendingDelete) return false;
      final raw = row['updated_at'] as String?;
      final previous = raw == null ? null : DateTime.tryParse(raw);
      final now = _now();
      final stamp = nextUpdatedAt(previous, now);
      final changed = changes(row);
      await txn.update(
        'medications',
        {
          ...changed,
          'sync_status': editedSyncStatus(status),
          'updated_at': stamp.toIso8601String(),
          'edited_at': editedAtText(stamp, now),
          'field_edited_at': fieldTimesAfterWrite(
            previous: row,
            after: {...row, ...changed},
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

  Future<MedicationModel?> getMedicationById(String id) async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<MedicationModel>> searchMedications(String query) async {
    final db = await _db;
    // Search in name, description, active ingredients (JSON), and notes
    final rows = await db.query(
      'medications',
      where:
          '(name LIKE ? OR description LIKE ? OR active_ingredients LIKE ? OR notes LIKE ?) AND sync_status != ?',
      whereArgs: [
        '%$query%',
        '%$query%',
        '%$query%',
        '%$query%',
        SyncStatus.pendingDelete,
      ],
      orderBy: 'name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<MedicationModel>> getExpiringSoon({int days = 30}) async {
    final now = _now();
    final threshold = now.add(Duration(days: days));
    final db = await _db;
    final rows = await db.query(
      'medications',
      where:
          'expiry_date >= ? AND expiry_date <= ? AND sync_status != ? AND (is_archived IS NULL OR is_archived = 0)',
      whereArgs: [
        now.toIso8601String().split('T').first,
        threshold.toIso8601String().split('T').first,
        SyncStatus.pendingDelete,
      ],
      orderBy: 'expiry_date ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<MedicationModel>> getLowStock() async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where:
          'quantity <= minimum_stock_level AND sync_status != ? AND (is_archived IS NULL OR is_archived = 0)',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'quantity ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// The medication whose label code or EAN is [barcode] (a pack carries
  /// both; a scan may produce either).
  ///
  /// Two rows can match one code — the app writes `barcode=<EAN>` for a plain
  /// EAN scan and `barcode=<label code>, ean=<EAN>` for a label scan of the
  /// same pack — so the order is explicit rather than left to the query plan
  /// (review I3): an exact `barcode` match first, then the EAN match, and
  /// `id` to break any remaining tie the same way on every device.
  Future<MedicationModel?> getMedicationByBarcode(String barcode) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT * FROM medications '
      'WHERE (barcode = ? OR ean = ?) AND sync_status != ? '
      'ORDER BY CASE WHEN barcode = ? THEN 0 ELSE 1 END, id '
      'LIMIT 1',
      [barcode, barcode, SyncStatus.pendingDelete, barcode],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Stores [model] as [syncStatus].
  ///
  /// [stockOp] is a quantity typed into the form, a count: it waits in the
  /// stock outbox, written in the same transaction, when [queueing] says so
  /// for the row as it was stored before.
  Future<void> upsert(
    MedicationModel model, {
    required String syncStatus,
    StockOp? stockOp,
    StockQueueing queueing = StockQueueing.always,
  }) async {
    final db = await _db;
    final at = _now();
    final row = rowOf(model, syncStatus, now: () => at);
    if (syncStatus == SyncStatus.synced && stockOp == null) {
      await _store(db, model.id, row);
      return;
    }
    await db.transaction((txn) async {
      final previous = await _stored(txn, model.id);
      if (syncStatus != SyncStatus.synced) {
        // A change made here: stamp the columns it changes.
        row['field_edited_at'] = fieldTimesAfterWrite(
          previous: previous,
          after: row,
          wireOf: wireOf,
          at: editedAtOf(model.updatedAt ?? at, at),
        );
      }
      await _store(txn, model.id, row);
      if (stockOp != null && previous != null && queueing.queues(previous)) {
        await StockOutboxLocalDatasource.enqueue(txn, stockOp);
      }
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
      'medications',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(
        'medications',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The wire copy of the stored row [row] (what the edit times compare).
  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      MedicationModel.fromLocalMap(row).toJson();

  /// Marks the row for deletion: pending push plus a local tombstone stamp
  /// (spec §4.6). A row already deleted keeps its stamps.
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      'medications',
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
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingChanges() async {
    final db = await _db;
    return db.query(
      'medications',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.synced],
    );
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('medications');
  }

  // ── Row mapping ────────────────────────────────────────────

  MedicationModel _fromRow(Map<String, dynamic> row) {
    return MedicationModel(
      id: row['id'] as String,
      userId: row['user_id'] as String?,
      name: row['name'] as String,
      description: row['description'] as String?,
      activeIngredients: MedicationModel.parseTags(
        row['active_ingredients'] ?? row['active_ingredient'],
      ),
      category: row['category'] as String?,
      manufacturer: row['manufacturer'] as String?,
      form: row['form'] as String?,
      atcCode: row['atc_code'] as String?,
      symptoms: MedicationModel.parseTags(row['symptoms']),
      patientTags: MedicationModel.parseTags(row['patient_tags']),
      purchaseDate: row['purchase_date'] != null
          ? DateTime.tryParse(row['purchase_date'] as String)
          : null,
      expiryDate: row['expiry_date'] != null
          ? DateTime.tryParse(row['expiry_date'] as String)
          : null,
      quantity: row['quantity'] as int? ?? 0,
      quantityUnit: row['quantity_unit'] as String?,
      minimumStockLevel: row['minimum_stock_level'] as int? ?? 0,
      storageLocation: row['storage_location'] as String?,
      barcode: row['barcode'] as String?,
      ean: row['ean'] as String?,
      imagePath: row['image_path'] as String?,
      notes: row['notes'] as String?,
      isArchived: (row['is_archived'] as int? ?? 0) == 1,
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
    MedicationModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      'id': m.id,
      'user_id': m.userId,
      'name': m.name,
      'description': m.description,
      'active_ingredients': jsonEncode(m.activeIngredients),
      'category': m.category,
      'manufacturer': m.manufacturer,
      'form': m.form,
      'atc_code': m.atcCode,
      'symptoms': jsonEncode(m.symptoms),
      'patient_tags': jsonEncode(m.patientTags),
      'purchase_date': m.purchaseDate?.toIso8601String().split('T').first,
      'expiry_date': m.expiryDate?.toIso8601String().split('T').first,
      'quantity': m.quantity,
      'quantity_unit': m.quantityUnit,
      'minimum_stock_level': m.minimumStockLevel,
      'storage_location': m.storageLocation,
      'barcode': m.barcode,
      'ean': m.ean,
      'image_path': m.imagePath,
      'notes': m.notes,
      'is_archived': m.isArchived ? 1 : 0,
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
