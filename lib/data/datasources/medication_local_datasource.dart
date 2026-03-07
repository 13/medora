/// Medora - Medication Local Datasource
///
/// Medora - Medication Local Datasource
library;

import 'dart:convert';

import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:sqflite/sqflite.dart';

class MedicationLocalDatasource {
  MedicationLocalDatasource();

  Future<Database> get _db => AppDatabase.instance.database;

  Future<List<MedicationModel>> getMedications() async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where: 'sync_status != ? AND (is_archived IS NULL OR is_archived = 0)',
      whereArgs: [SyncStatus.pendingDelete],
      orderBy: 'name ASC',
    );
    return rows.map((r) => _fromRow(r)).toList();
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
    return rows.map((r) => _fromRow(r)).toList();
  }

  /// Archive a medication.
  Future<void> archiveMedication(String id) async {
    final db = await _db;
    await db.update(
      'medications',
      {
        'is_archived': 1,
        'sync_status': SyncStatus.pendingUpdate,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Unarchive a medication.
  Future<void> unarchiveMedication(String id) async {
    final db = await _db;
    await db.update(
      'medications',
      {
        'is_archived': 0,
        'sync_status': SyncStatus.pendingUpdate,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<MedicationModel?> getMedicationById(String id) async {
    final db = await _db;
    final rows = await db.query('medications', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<MedicationModel>> searchMedications(String query) async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where:
          "(name LIKE ? OR active_ingredient LIKE ?) AND sync_status != ?",
      whereArgs: ['%$query%', '%$query%', SyncStatus.pendingDelete],
      orderBy: 'name ASC',
    );
    return rows.map((r) => _fromRow(r)).toList();
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
    return rows.map((r) => _fromRow(r)).toList();
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
    return rows.map((r) => _fromRow(r)).toList();
  }

  Future<MedicationModel?> getMedicationByBarcode(String barcode) async {
    final db = await _db;
    final rows = await db.query(
      'medications',
      where: 'barcode = ? AND sync_status != ?',
      whereArgs: [barcode, SyncStatus.pendingDelete],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> upsert(MedicationModel model, {required String syncStatus}) async {
    final db = await _db;
    await db.insert(
      'medications',
      _toRow(model, syncStatus),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markDeleted(String id) async {
    final db = await _db;
    await db.update(
      'medications',
      {'sync_status': SyncStatus.pendingDelete},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _db;
    await db.delete('medications', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>> > getPendingChanges() async {
    final db = await _db;
    return db.query(
      'medications',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.synced],
    );
  }

  Future<void> markSynced(String id) async {
    final db = await _db;
    await db.update(
      'medications',
      {'sync_status': SyncStatus.synced},
      where: 'id = ?',
      whereArgs: [id],
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
          row['active_ingredients'] ?? row['active_ingredient']),
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
      minimumStockLevel: row['minimum_stock_level'] as int? ?? 5,
      storageLocation: row['storage_location'] as String?,
      barcode: row['barcode'] as String?,
      imagePath: row['image_path'] as String?,
      notes: row['notes'] as String?,
      isArchived: (row['is_archived'] as int? ?? 0) == 1,
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'] as String)
          : null,
      updatedAt: row['updated_at'] != null
          ? DateTime.tryParse(row['updated_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> _toRow(MedicationModel m, String syncStatus) {
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
      'image_path': m.imagePath,
      'notes': m.notes,
      'is_archived': m.isArchived ? 1 : 0,
      'created_at': m.createdAt?.toIso8601String() ??
          DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'sync_status': syncStatus,
    };
  }
}

