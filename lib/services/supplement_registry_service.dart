/// Medora - food-supplement register (offline cache)
///
/// The Italian Ministry of Health publishes the register of notified food
/// supplements monthly as a PDF; `tools/build_supplements_data.py` converts it
/// to `integratori.csv.gz` (`code,product,company`) plus
/// `integratori.meta.json` on the GitHub pre-release `data-integratori`. This
/// service downloads both, stores the rows in its own SQLite database
/// (`supplement_cache.db`) and looks up the notification code ("COD MINSAN")
/// printed on supplement labels. Not available on the web (no `dart:io` gzip,
/// no file-backed SQLite); see `PlatformCapabilities.hasSupplementRegister`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:medora/core/clock.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// One product of the register.
@immutable
class SupplementEntry {
  const SupplementEntry({
    required this.code,
    required this.product,
    required this.company,
  });

  /// The notification code as listed in the register (digits).
  final String code;
  final String product;
  final String company;

  @override
  bool operator ==(Object other) =>
      other is SupplementEntry &&
      other.code == code &&
      other.product == product &&
      other.company == company;

  @override
  int get hashCode => Object.hash(code, product, company);

  @override
  String toString() => 'SupplementEntry($code, $product, $company)';
}

class SupplementRegistryService {
  SupplementRegistryService({
    this._client,
    Future<Database> Function()? openDatabase,
    Now? now,
  }) : _openDatabase = openDatabase ?? _openDefaultDatabase,
       _now = now ?? systemNow;

  static const dataUrl =
      'https://github.com/13/medora/releases/download/data-integratori/integratori.csv.gz';
  static const metaUrl =
      'https://github.com/13/medora/releases/download/data-integratori/integratori.meta.json';

  static const _dbName = 'supplement_cache.db';
  static const _table = 'supplements';
  static const _prefLastSync = 'supplement_last_sync';
  static const _prefCount = 'supplement_count';
  static const _prefSourceUpdated = 'supplement_source_updated';
  static const _codeKeyIndex = 'idx_supplements_code_key';
  static const _insertChunk = 5000;
  static const _timeout = Duration(seconds: 120);

  final http.Client? _client;
  final Future<Database> Function() _openDatabase;
  final Now _now;
  Future<Database>? _database;

  /// The download in progress, shared by concurrent [sync] calls.
  Future<int>? _syncing;
  final _progressListeners = <void Function(double progress)>[];

  static Future<Database> _openDefaultDatabase() async =>
      openDatabase(p.join(await getDatabasesPath(), _dbName));

  /// The opened database; a failed open is not cached, so the next call
  /// tries again.
  Future<Database> get _db {
    final opening = _database ??= _openAndPrepare();
    return opening.catchError((Object error, StackTrace stack) {
      if (identical(_database, opening)) _database = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<Database> _openAndPrepare() async {
    final db = await _openDatabase();
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_table ('
      'code TEXT NOT NULL, code_key TEXT NOT NULL, '
      'product TEXT NOT NULL, company TEXT NOT NULL)',
    );
    return db;
  }

  /// When the register was last downloaded, or null if never.
  Future<DateTime?> lastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefLastSync);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Number of cached products (0 before the first download).
  Future<int> count() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefCount) ?? 0;
  }

  /// The Ministry's "aggiornato al" date of the cached register, if known.
  Future<DateTime?> sourceUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_prefSourceUpdated);
    return value == null ? null : DateTime.tryParse(value);
  }

  Future<bool> hasData() async => await count() > 0;

  /// Downloads the register and replaces the cached table in one
  /// transaction. Download or format errors throw and leave the previous
  /// table untouched. [onProgress] receives 0..1 (the download part only
  /// when its size is known). Returns the stored row count.
  ///
  /// A call while a download is running joins it (one download; every
  /// caller's [onProgress] is notified and gets the same result).
  Future<int> sync({void Function(double progress)? onProgress}) {
    if (onProgress != null) _progressListeners.add(onProgress);
    return _syncing ??= _runSync().whenComplete(() {
      _syncing = null;
      _progressListeners.clear();
    });
  }

  void _reportProgress(double progress) {
    for (final listener in List.of(_progressListeners)) {
      listener(progress);
    }
  }

  Future<int> _runSync() async {
    final client = _client ?? http.Client();
    try {
      final bytes = await _download(client, _reportProgress);
      final entries = await compute(parseRegisterGzip, bytes);
      if (entries.isEmpty) {
        throw const FormatException('The supplement register is empty');
      }
      final updated = await _fetchSourceUpdated(client);
      _reportProgress(0.8);

      final db = await _db;
      await db.transaction((txn) async {
        // Bulk insert without the index, then build it once.
        await txn.execute('DROP INDEX IF EXISTS $_codeKeyIndex');
        await txn.delete(_table);
        for (var i = 0; i < entries.length; i += _insertChunk) {
          final batch = txn.batch();
          for (final e in entries.skip(i).take(_insertChunk)) {
            batch.insert(_table, {
              'code': e.code,
              'code_key': codeKey(e.code),
              'product': e.product,
              'company': e.company,
            });
          }
          await batch.commit(noResult: true);
          _reportProgress(
            0.8 +
                0.2 *
                    (i + _insertChunk).clamp(0, entries.length) /
                    entries.length,
          );
        }
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS $_codeKeyIndex ON $_table(code_key)',
        );
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSync, _now().millisecondsSinceEpoch);
      await prefs.setInt(_prefCount, entries.length);
      if (updated != null) {
        await prefs.setString(_prefSourceUpdated, updated);
      } else {
        await prefs.remove(_prefSourceUpdated);
      }
      debugPrint('Supplement register synced: ${entries.length} products');
      return entries.length;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<Uint8List> _download(
    http.Client client,
    void Function(double progress)? onProgress,
  ) async {
    final response = await client
        .send(http.Request('GET', Uri.parse(dataUrl)))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Supplement register download failed: ${response.statusCode}',
        Uri.parse(dataUrl),
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_timeout)) {
      builder.add(chunk);
      if (total != null && total > 0) {
        onProgress?.call(0.7 * (builder.length / total).clamp(0.0, 1.0));
      }
    }
    return builder.takeBytes();
  }

  /// `sourceUpdated` (yyyy-mm-dd) from the meta file; null when unavailable.
  Future<String?> _fetchSourceUpdated(http.Client client) async {
    try {
      final response = await client
          .get(Uri.parse(metaUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      final value = json is Map ? json['sourceUpdated'] : null;
      return value is String && DateTime.tryParse(value) != null ? value : null;
    } catch (e) {
      debugPrint('Supplement register meta unavailable: $e');
      return null;
    }
  }

  /// Register entries for a scanned code; non-digits are ignored and
  /// leading zeros do not matter (`0107018` finds `107018`).
  Future<List<SupplementEntry>> findByCode(String code) async {
    final key = codeKey(code);
    if (key.isEmpty || !await hasData()) return const [];
    final rows = await (await _db).query(
      _table,
      where: 'code_key = ?',
      whereArgs: [key],
      orderBy: 'product',
    );
    return rows.map(_entryFromRow).toList();
  }

  /// Products whose name contains [query] (case-insensitive).
  Future<List<SupplementEntry>> searchByName(
    String query, {
    int limit = 50,
  }) async {
    final term = query.trim();
    if (term.length < 2 || !await hasData()) return const [];
    final rows = await (await _db).query(
      _table,
      where: 'UPPER(product) LIKE ?',
      whereArgs: ['%${term.toUpperCase()}%'],
      orderBy: 'product',
      limit: limit,
    );
    return rows.map(_entryFromRow).toList();
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await (await db).close();
  }

  static SupplementEntry _entryFromRow(Map<String, Object?> row) =>
      SupplementEntry(
        code: row['code']! as String,
        product: row['product']! as String,
        company: row['company']! as String,
      );

  /// The lookup key of a code: its digits without leading zeros.
  @visibleForTesting
  static String codeKey(String code) =>
      code.replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+'), '');
}

/// Gunzips and parses `integratori.csv.gz` (header `code,product,company`).
/// Throws [FormatException] for non-gzip data or a different header. Rows
/// without a numeric code are skipped. Top-level so it can run in `compute`.
@visibleForTesting
List<SupplementEntry> parseRegisterGzip(Uint8List bytes) {
  final List<int> raw;
  try {
    raw = gzip.decode(bytes);
  } catch (e) {
    throw FormatException('The supplement register is not gzip data: $e');
  }
  final rows = Csv().decode(utf8.decode(raw));
  if (rows.isEmpty ||
      rows.first.map((c) => '$c'.trim()).join(',') != 'code,product,company') {
    throw const FormatException('Unexpected supplement register header');
  }
  final digits = RegExp(r'^\d+$');
  return [
    for (final row in rows.skip(1))
      if (row.length >= 3 && digits.hasMatch('${row[0]}'.trim()))
        SupplementEntry(
          code: '${row[0]}'.trim(),
          product: '${row[1]}'.trim(),
          company: '${row[2]}'.trim(),
        ),
  ];
}
