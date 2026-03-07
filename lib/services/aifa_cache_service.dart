/// Medora - AIFA Database Local Cache Service
///
/// Downloads and caches the AIFA confezioni.csv locally in SQLite.
/// Provides fast local search by AIC code.
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class AifaCacheService {
  AifaCacheService._();
  static final instance = AifaCacheService._();

  static const _aifaUrl = 'https://drive.aifa.gov.it/farmaci/confezioni.csv';
  static const _dbName = 'aifa_cache.db';
  static const _prefLastSync = 'aifa_last_sync';
  static const _prefCount = 'aifa_count';

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = p.join(await getDatabasesPath(), _dbName);
    _database = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS aifa_medications (
            code TEXT PRIMARY KEY,
            group_code TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT,
            manufacturer TEXT,
            status TEXT,
            form TEXT,
            atc_code TEXT,
            active_ingredient TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_aifa_group ON aifa_medications(group_code)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_aifa_name ON aifa_medications(name)');
      },
    );
    return _database!;
  }

  /// Get the last sync date, or null if never synced.
  Future<DateTime?> getLastSyncDate() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefLastSync);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Get the count of cached medications.
  Future<int> getCachedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefCount) ?? 0;
  }

  /// Check if we have cached data.
  Future<bool> hasCachedData() async {
    final count = await getCachedCount();
    return count > 0;
  }

  /// Download the AIFA CSV and store it in the local database.
  /// Returns the number of records stored.
  Future<int> syncDatabase({
    http.Client? client,
    void Function(String status)? onProgress,
  }) async {
    final httpClient = client ?? http.Client();

    onProgress?.call('Downloading…');
    final response = await httpClient
        .get(Uri.parse(_aifaUrl), headers: {'User-Agent': 'Medora/1.0'})
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Failed to download AIFA database: ${response.statusCode}');
    }

    onProgress?.call('Parsing…');
    final lines = response.body.split('\n');

    final db = await database;

    onProgress?.call('Storing…');
    // Use a batch for fast insertion
    await db.transaction((txn) async {
      await txn.delete('aifa_medications');

      int count = 0;
      final batch = txn.batch();

      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final fields = line.split(';');
        if (fields.length < 12) continue;

        batch.insert(
          'aifa_medications',
          {
            'code': fields[0].trim(),
            'group_code': fields[1].trim(),
            'name': fields[3].trim(),
            'description': fields[4].trim(),
            'manufacturer': fields[6].trim(),
            'status': fields[7].trim(),
            'form': fields[9].trim(),
            'atc_code': fields[10].trim(),
            'active_ingredient': fields[11].trim(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        count++;

        // Commit in batches of 5000 to avoid memory issues
        if (count % 5000 == 0) {
          await batch.commit(noResult: true);
          onProgress?.call('Stored $count records…');
        }
      }

      await batch.commit(noResult: true);
      return count;
    });

    // Get actual count
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM aifa_medications');
    final count = Sqflite.firstIntValue(result) ?? 0;

    // Store sync metadata
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefLastSync, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_prefCount, count);

    debugPrint('AIFA database synced: $count medications');
    return count;
  }

  /// Search the local AIFA cache by AIC code.
  /// Falls back to remote CSV if no local data.
  Future<List<AifaSearchResult>> search(String code) async {
    final cleanedCode = BarcodeLookupDatasource.cleanCode(code);
    if (cleanedCode.length < 6) return [];

    final hasData = await hasCachedData();
    if (!hasData) {
      // Fall back to remote search
      return BarcodeLookupDatasource().search(code);
    }

    final db = await database;

    // Search by exact code, group code, or prefix
    final rows = await db.query(
      'aifa_medications',
      where: 'code = ? OR group_code = ? OR code LIKE ?',
      whereArgs: [cleanedCode, cleanedCode, '$cleanedCode%'],
      orderBy: "CASE WHEN code = '$cleanedCode' THEN 0 ELSE 1 END, name",
      limit: 50,
    );

    return rows.map((row) => AifaSearchResult(
      code: row['code'] as String,
      groupCode: row['group_code'] as String,
      name: _titleCase(row['name'] as String),
      description: row['description'] as String? ?? '',
      manufacturer: _nonEmpty(row['manufacturer'] as String?),
      status: _nonEmpty(row['status'] as String?),
      form: _nonEmpty(row['form'] as String?),
      atcCode: _nonEmpty(row['atc_code'] as String?),
      activeIngredient: _nonEmpty(row['active_ingredient'] as String?) != null
          ? _titleCase(row['active_ingredient'] as String)
          : null,
    )).toList();
  }

  /// Search the local AIFA cache by medication name or active ingredient.
  Future<List<AifaSearchResult>> searchByName(String query) async {
    if (query.length < 2) return [];

    final hasData = await hasCachedData();
    if (!hasData) return [];

    final db = await database;
    final term = '%${query.toUpperCase()}%';

    final rows = await db.query(
      'aifa_medications',
      where: 'UPPER(name) LIKE ? OR UPPER(active_ingredient) LIKE ? OR UPPER(description) LIKE ?',
      whereArgs: [term, term, term],
      orderBy: "CASE WHEN UPPER(name) LIKE '$term' THEN 0 ELSE 1 END, name",
      limit: 50,
    );

    return rows.map((row) => AifaSearchResult(
      code: row['code'] as String,
      groupCode: row['group_code'] as String,
      name: _titleCase(row['name'] as String),
      description: row['description'] as String? ?? '',
      manufacturer: _nonEmpty(row['manufacturer'] as String?),
      status: _nonEmpty(row['status'] as String?),
      form: _nonEmpty(row['form'] as String?),
      atcCode: _nonEmpty(row['atc_code'] as String?),
      activeIngredient: _nonEmpty(row['active_ingredient'] as String?) != null
          ? _titleCase(row['active_ingredient'] as String)
          : null,
    )).toList();
  }

  /// Close the database.
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  static String? _nonEmpty(String? s) =>
      (s != null && s.trim().isNotEmpty) ? s.trim() : null;

  static String _titleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((w) => w.isNotEmpty
            ? '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}'
            : '')
        .join(' ');
  }
}


