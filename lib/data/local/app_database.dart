/// Medora - Local SQLite Database
///
/// Provides offline-first storage for all entities.
library;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:medora/data/local/migrations.dart';
import 'package:path/path.dart';
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

  /// Test-only: when set, the database opens at this path
  /// (use [inMemoryDatabasePath] for a throwaway database).
  @visibleForTesting
  static String? debugPathOverride;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final path =
        debugPathOverride ??
        (kIsWeb ? 'medora.db' : join(await getDatabasesPath(), 'medora.db'));

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await createBaseSchema(db);
          await _createLedger(db);
          for (final m in kMigrations) {
            await m.run(db);
            await _record(db, m.version);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await _createLedger(db);
          final applied = (await _applied(db)).toSet();
          for (final m in kMigrations) {
            if (applied.contains(m.version)) continue;
            if (m.version <= oldVersion) {
              // Schema already reflects this migration (pre-dates the
              // ledger, or the ledger was created fresh on this upgrade);
              // backfill the record without re-running it.
              await _record(db, m.version);
              continue;
            }
            await m.run(db);
            await _record(db, m.version);
          }
        },
      ),
    );
  }

  static Future<void> _createLedger(Database db) => db.execute(
    'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)',
  );

  static Future<void> _record(Database db, int version) => db.insert(
    'schema_migrations',
    {'version': version, 'applied_at': DateTime.now().toIso8601String()},
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  static Future<List<int>> _applied(Database db) async {
    final rows = await db.query(
      'schema_migrations',
      columns: ['version'],
      orderBy: 'version',
    );
    return rows.map((r) => r['version'] as int).toList();
  }

  /// Versions recorded in `schema_migrations`, ascending.
  Future<List<int>> appliedMigrations() async => _applied(await database);

  /// The base (v10) schema. New columns go into [kMigrations], not here.
  static Future<void> createBaseSchema(Database db) async {
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
        updated_at TEXT,
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
      'CREATE INDEX idx_local_med_barcode ON medications(barcode)',
    );
    await db.execute(
      'CREATE INDEX idx_local_med_expiry ON medications(expiry_date)',
    );
    await db.execute(
      'CREATE INDEX idx_local_med_sync ON medications(sync_status)',
    );
    await db.execute(
      'CREATE INDEX idx_local_treat_active ON treatments(is_active)',
    );
    await db.execute(
      'CREATE INDEX idx_local_treat_sync ON treatments(sync_status)',
    );
    await db.execute(
      'CREATE INDEX idx_local_presc_treatment ON prescriptions(treatment_id)',
    );
    await db.execute(
      'CREATE INDEX idx_local_presc_sync ON prescriptions(sync_status)',
    );
    await db.execute(
      'CREATE INDEX idx_local_dose_presc ON dose_logs(prescription_id)',
    );
    await db.execute(
      'CREATE INDEX idx_local_dose_sched ON dose_logs(scheduled_time)',
    );
    await db.execute(
      'CREATE INDEX idx_local_dose_sync ON dose_logs(sync_status)',
    );
  }

  Future<void> clearAllData() async {
    final db = await database;
    // First: its rows reference medications.
    await db.delete('stock_outbox');
    await db.delete('dose_logs');
    await db.delete('prescriptions');
    await db.delete('treatments');
    await db.delete('medications');
    await db.delete('family_members');
    await db.delete('families');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// Test-only: close and forget the cached handle.
  @visibleForTesting
  Future<void> reset() => close();
}
