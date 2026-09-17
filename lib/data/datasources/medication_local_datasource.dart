/// Medora - Medication Local Datasource
library;

import 'dart:convert';

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:sqflite/sqflite.dart';

class MedicationLocalDatasource {
  MedicationLocalDatasource();

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

  /// Adds [delta] to the stock, never going below zero. Returns the stored
  /// row, or null (and changes nothing) when the medication is missing or
  /// deleted. Only the quantity and the bookkeeping columns are written, so
  /// no other column can be lost on the way.
  Future<MedicationModel?> adjustQuantity(String id, int delta) async {
    final changed = await _editRow(id, (row) {
      final current = row['quantity'] as int? ?? 0;
      return {'quantity': (current + delta).clamp(0, 999999)};
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
  ///   `edited_at` records the same instant;
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
      final stamp = nextUpdatedAt(previous, DateTime.now()).toIso8601String();
      await txn.update(
        'medications',
        {
          ...changes(row),
          'sync_status': editedSyncStatus(status),
          'updated_at': stamp,
          'edited_at': stamp,
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
    final now = DateTime.now();
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

  Future<void> upsert(
    MedicationModel model, {
    required String syncStatus,
  }) async {
    final db = await _db;
    final row = rowOf(model, syncStatus);
    // Use UPDATE-first to avoid DELETE+INSERT from ConflictAlgorithm.replace,
    // which would CASCADE-DELETE prescriptions and dose_logs.
    final updated = await db.update(
      'medications',
      row,
      where: 'id = ?',
      whereArgs: [model.id],
    );
    if (updated == 0) {
      await db.insert(
        'medications',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// Marks the row for deletion: pending push plus a local tombstone stamp
  /// (spec §4.6).
  Future<void> markDeleted(String id) async {
    final db = await _db;
    await db.update(
      'medications',
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': DateTime.now().toIso8601String(),
        'edited_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
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

  static Map<String, dynamic> rowOf(MedicationModel m, String syncStatus) {
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
      'created_at':
          m.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'updated_at':
          m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      'sync_status': syncStatus,
      // A change made here was made when it was stamped; a pulled row gets
      // the server's edit time from the sync cycle instead.
      if (syncStatus != SyncStatus.synced)
        'edited_at':
            m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
    };
  }
}
