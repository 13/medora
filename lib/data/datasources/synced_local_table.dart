/// Medora - The local side of a table synced by sync v2, for the tables
/// added after it (persons, rx, rx_dispensings).
///
/// The four original tables each spell this out in their own datasource;
/// the newer ones share it. A write stored as pending is stamped the way
/// the sync cycle expects (`edited_at`, per-column `field_edited_at`); a
/// row stored as synced comes from the server and keeps the stamps the
/// cycle gives it.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:sqflite/sqflite.dart';

class SyncedLocalTable<M> {
  SyncedLocalTable({
    required this.table,
    required this.rowOf,
    required this.wireOf,
    required this.fromRow,
    required this.updatedAtOf,
    // Named `now` on the outside; kept private once stored (matches the
    // hand-written datasources' `_now`).
    required Now now,
    // ignore: prefer_initializing_formals
  }) : _now = now;

  final String table;

  /// The stored row of a model (data columns, `sync_status`, and
  /// `edited_at` for a pending write).
  final Map<String, dynamic> Function(M model, String syncStatus, {Now now})
  rowOf;

  /// The wire copy of a stored row, which the edit times compare.
  final Map<String, Object?> Function(Map<String, Object?> row) wireOf;
  final M Function(Map<String, dynamic> row) fromRow;
  final DateTime? Function(M model) updatedAtOf;
  final Now _now;

  Future<Database> get _db => AppDatabase.instance.database;

  Future<void> upsert(M model, {required String syncStatus}) async {
    final db = await _db;
    final at = _now();
    final row = rowOf(model, syncStatus, now: () => at);
    final id = row['id'] as String;
    if (syncStatus == SyncStatus.synced) {
      await _store(db, id, row);
      return;
    }
    await db.transaction((txn) async {
      row['field_edited_at'] = fieldTimesAfterWrite(
        previous: await _stored(txn, id),
        after: row,
        wireOf: wireOf,
        at: editedAtOf(updatedAtOf(model) ?? at, at),
      );
      await _store(txn, id, row);
    });
  }

  /// UPDATE first: INSERT OR REPLACE deletes the row first and would
  /// cascade-delete its children (an rx's dispensings).
  Future<void> _store(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> row,
  ) async {
    final updated = await db.update(
      table,
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Marks the row for deletion (pending push, local tombstone). A row
  /// already deleted keeps its stamps.
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      table,
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': now.toIso8601String(),
        'edited_at': editedAtText(now, now),
      },
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.pendingDelete],
    );
  }

  /// The row [id], tombstone included, or null.
  Future<M?> getById(String id) async {
    final rows = await (await _db).query(
      table,
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : fromRow(rows.first);
  }

  /// Live rows (a pending delete is hidden) matching [where].
  Future<List<M>> getAll({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    final rows = await (await _db).query(
      table,
      where: where == null
          ? 'sync_status != ?'
          : '($where) AND sync_status != ?',
      whereArgs: [...?whereArgs, SyncStatus.pendingDelete],
      orderBy: orderBy,
    );
    return rows.map(fromRow).toList();
  }

  Future<void> hardDelete(String id) async =>
      (await _db).delete(table, where: 'id = ?', whereArgs: [id]);

  Future<void> clearAll() async => (await _db).delete(table);

  /// Stamp shared by every `rowOf`: the pending write's `edited_at`.
  static Map<String, Object?> pendingStamp(
    String syncStatus,
    DateTime? updatedAt,
    DateTime at,
  ) => {
    'sync_status': syncStatus,
    if (syncStatus != SyncStatus.synced)
      'edited_at': editedAtText(updatedAt ?? at, at),
  };
}
