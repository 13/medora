/// Medora - Local SQLite Database
///
/// Provides offline-first storage for all entities.
/// Each table mirrors the Supabase schema with an additional
/// `sync_status` column for tracking pending changes.
library;

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Sync status for local records.
class SyncStatus {
  SyncStatus._();
  static const String synced = 'synced';
  static const String pendingCreate = 'pending_create';
  static const String pendingUpdate = 'pending_update';
  static const String pendingDelete = 'pending_delete';
}

/// Singleton database helper for the app.
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = join(dir.path, 'medora.db');
    return openDatabase(
      dbPath,
      version: 9,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE medications (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        family_id TEXT,
        name TEXT NOT NULL,
        description TEXT,
        active_ingredients TEXT,
        category TEXT,
        manufacturer TEXT,
        form TEXT,
        atc_code TEXT,
        symptoms TEXT,
        patient_tags TEXT,
        purchase_date TEXT,
        expiry_date TEXT,
        quantity INTEGER NOT NULL DEFAULT 0,
        quantity_unit TEXT,
        minimum_stock_level INTEGER NOT NULL DEFAULT 0,
        storage_location TEXT,
        barcode TEXT,
        image_path TEXT,
        notes TEXT,
        is_archived INTEGER NOT NULL DEFAULT 0,
        created_at TEXT,
        updated_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced'
      )
    ''');

    await db.execute('''
      CREATE TABLE treatments (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        family_id TEXT,
        name TEXT NOT NULL,
        patient_tags TEXT,
        symptom_tags TEXT,
        start_date TEXT NOT NULL,
        end_date TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        created_at TEXT,
        updated_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced'
      )
    ''');

    await db.execute('''
      CREATE TABLE prescriptions (
        id TEXT PRIMARY KEY,
        treatment_id TEXT NOT NULL,
        medication_id TEXT NOT NULL,
        dosage TEXT NOT NULL,
        dosage_amount REAL,
        dosage_unit TEXT,
        interval_hours INTEGER NOT NULL DEFAULT 8,
        duration_days INTEGER NOT NULL DEFAULT 7,
        start_time TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        auto_diminish INTEGER NOT NULL DEFAULT 0,
        notes TEXT,
        created_at TEXT,
        updated_at TEXT,
        schedule_type TEXT NOT NULL DEFAULT 'fixed_interval',
        schedule_times TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        FOREIGN KEY (treatment_id) REFERENCES treatments(id) ON DELETE CASCADE,
        FOREIGN KEY (medication_id) REFERENCES medications(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE dose_logs (
        id TEXT PRIMARY KEY,
        prescription_id TEXT NOT NULL,
        scheduled_time TEXT NOT NULL,
        taken_time TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        notes TEXT,
        created_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        FOREIGN KEY (prescription_id) REFERENCES prescriptions(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE families (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        invite_code TEXT UNIQUE,
        owner_id TEXT,
        created_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced'
      )
    ''');

    await db.execute('''
      CREATE TABLE family_members (
        id TEXT PRIMARY KEY,
        family_id TEXT NOT NULL,
        user_id TEXT,
        display_name TEXT,
        role TEXT NOT NULL DEFAULT 'member',
        joined_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE
      )
    ''');

    // Indexes
    await db.execute(
        'CREATE INDEX idx_local_med_barcode ON medications(barcode)');
    await db.execute(
        'CREATE INDEX idx_local_med_expiry ON medications(expiry_date)');
    await db.execute(
        'CREATE INDEX idx_local_med_sync ON medications(sync_status)');
    await db.execute(
        'CREATE INDEX idx_local_treat_active ON treatments(is_active)');
    await db.execute(
        'CREATE INDEX idx_local_treat_sync ON treatments(sync_status)');
    await db.execute(
        'CREATE INDEX idx_local_presc_treatment ON prescriptions(treatment_id)');
    await db.execute(
        'CREATE INDEX idx_local_presc_sync ON prescriptions(sync_status)');
    await db.execute(
        'CREATE INDEX idx_local_dose_presc ON dose_logs(prescription_id)');
    await db.execute(
        'CREATE INDEX idx_local_dose_sched ON dose_logs(scheduled_time)');
    await db.execute(
        'CREATE INDEX idx_local_dose_sync ON dose_logs(sync_status)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add family_id columns and family tables
      await db.execute(
          'ALTER TABLE medications ADD COLUMN family_id TEXT');
      await db.execute(
          'ALTER TABLE treatments ADD COLUMN family_id TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS families (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          invite_code TEXT UNIQUE,
          owner_id TEXT,
          created_at TEXT,
          sync_status TEXT NOT NULL DEFAULT 'synced'
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS family_members (
          id TEXT PRIMARY KEY,
          family_id TEXT NOT NULL,
          user_id TEXT,
          display_name TEXT,
          role TEXT NOT NULL DEFAULT 'member',
          joined_at TEXT,
          sync_status TEXT NOT NULL DEFAULT 'synced',
          FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE
        )
      ''');
    }

    if (oldVersion < 3) {
      // Add flexible scheduling columns to prescriptions
      await db.execute(
          "ALTER TABLE prescriptions ADD COLUMN schedule_type TEXT NOT NULL DEFAULT 'fixed_interval'");
      await db.execute(
          'ALTER TABLE prescriptions ADD COLUMN schedule_times TEXT');
    }

    if (oldVersion < 4) {
      // Add patient_name to treatments (for baby / family member treatments)
      await db.execute(
          'ALTER TABLE treatments ADD COLUMN patient_name TEXT');
      // Add image_path to medications (for medication photos)
      await db.execute(
          'ALTER TABLE medications ADD COLUMN image_path TEXT');
    }

    if (oldVersion < 5) {
      // Rename active_ingredient to active_ingredients (JSON array)
      // SQLite doesn't support RENAME COLUMN on old versions,
      // so we add the new columns alongside old ones.
      try {
        await db.execute(
            'ALTER TABLE medications ADD COLUMN active_ingredients TEXT');
      } catch (_) {} // Column may already exist in fresh installs
      try {
        await db.execute(
            'ALTER TABLE medications ADD COLUMN symptoms TEXT');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE medications ADD COLUMN patient_tags TEXT');
      } catch (_) {}
      // Migrate old single active_ingredient to new JSON array column
      final rows = await db.query('medications',
          columns: ['id', 'active_ingredient'],
          where: 'active_ingredient IS NOT NULL AND active_ingredient != ?',
          whereArgs: ['']);
      for (final row in rows) {
        final id = row['id'] as String;
        final old = row['active_ingredient'] as String;
        await db.update(
            'medications', {'active_ingredients': '["$old"]'},
            where: 'id = ? AND (active_ingredients IS NULL OR active_ingredients = ?)',
            whereArgs: [id, '']);
      }
    }

    if (oldVersion < 6) {
      // Add tag columns to treatments
      try {
        await db.execute(
            'ALTER TABLE treatments ADD COLUMN patient_tags TEXT');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE treatments ADD COLUMN symptom_tags TEXT');
      } catch (_) {}
      // Migrate existing patient_name → patient_tags JSON array
      final rows = await db.query('treatments',
          columns: ['id', 'patient_name', 'symptoms'],
          where: "(patient_name IS NOT NULL AND patient_name != '') OR (symptoms IS NOT NULL AND symptoms != '')");
      for (final row in rows) {
        final id = row['id'] as String;
        final pn = row['patient_name'] as String?;
        final sy = row['symptoms'] as String?;
        final updates = <String, dynamic>{};
        if (pn != null && pn.isNotEmpty) {
          updates['patient_tags'] = '["$pn"]';
        }
        if (sy != null && sy.isNotEmpty) {
          updates['symptom_tags'] = '["$sy"]';
        }
        if (updates.isNotEmpty) {
          await db.update('treatments', updates, where: 'id = ?', whereArgs: [id]);
        }
      }
    }
    if (oldVersion < 7) {
      // Add description, manufacturer, form, atc_code columns to medications
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN description TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN manufacturer TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN form TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN atc_code TEXT');
      } catch (_) {}
    }

    if (oldVersion < 8) {
      // Add quantity_unit and is_archived to medications
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN quantity_unit TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      // Add auto_diminish to prescriptions
      try {
        await db.execute('ALTER TABLE prescriptions ADD COLUMN auto_diminish INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
    }

    if (oldVersion < 9) {
      // Add dosage_amount and dosage_unit to prescriptions
      try {
        await db.execute('ALTER TABLE prescriptions ADD COLUMN dosage_amount REAL');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE prescriptions ADD COLUMN dosage_unit TEXT');
      } catch (_) {}
    }
  }

  /// Delete all data from all tables.
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('dose_logs');
    await db.delete('prescriptions');
    await db.delete('treatments');
    await db.delete('medications');
    await db.delete('family_members');
    await db.delete('families');
  }

  /// Close the database.
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}

