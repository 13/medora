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
  // A private field initialized from a constructor parameter, matching the
  // hand-written datasources' `_now` (e.g. `TreatmentLocalDatasource`):
  // callers pass it as `now:` (Dart drops the leading underscore from a
  // `this._field` parameter's name).
  SyncedLocalTable({
    required this.table,
    required this.rowOf,
    required this.wireOf,
    required this.fromRow,
    required this.updatedAtOf,
    required this._now,
  });

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
    await db.transaction(
      (txn) async => _storePending(txn, model, row, await _stored(txn, id), at),
    );
  }

  /// Stores [row] (of [model]) as a pending write over [previous], stamping
  /// `field_edited_at` for the columns that changed.
  Future<void> _storePending(
    DatabaseExecutor txn,
    M model,
    Map<String, dynamic> row,
    Map<String, Object?>? previous,
    DateTime at,
  ) async {
    row['field_edited_at'] = fieldTimesAfterWrite(
      previous: previous,
      after: row,
      wireOf: wireOf,
      at: editedAtOf(updatedAtOf(model) ?? at, at),
    );
    await _store(txn, row['id'] as String, row);
  }

  /// Within [txn]: when the row [id] exists and is not deleted, stores
  /// [change] of it as a pending write ([syncStatus]), stamped as [upsert]
  /// stamps it, and returns true. Returns false and writes nothing when the
  /// row is gone or deleted, so a delete that lands between a caller's read
  /// and this write is never overwritten by a live row.
  Future<bool> updateLiveIn(
    Transaction txn,
    String id,
    M Function(M current) change, {
    required String syncStatus,
  }) async {
    assert(syncStatus != SyncStatus.synced, 'a pending write only');
    final previous = await _stored(txn, id);
    if (previous == null ||
        previous['deleted_at'] != null ||
        previous['sync_status'] == SyncStatus.pendingDelete) {
      return false;
    }
    final at = _now();
    final model = change(fromRow(previous));
    await _storePending(
      txn,
      model,
      rowOf(model, syncStatus, now: () => at),
      previous,
      at,
    );
    return true;
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

  /// The bookkeeping stamps shared by every `rowOf`: `created_at`,
  /// `updated_at`, `deleted_at` (defaulting the first two to [at], a new
  /// row's write time), `sync_status`, and, for a pending write, `edited_at`.
  static Map<String, Object?> rowStamps(
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    String syncStatus,
    DateTime at,
  ) => {
    'created_at': (createdAt ?? at).toIso8601String(),
    'updated_at': (updatedAt ?? at).toIso8601String(),
    'deleted_at': deletedAt?.toIso8601String(),
    'sync_status': syncStatus,
    if (syncStatus != SyncStatus.synced)
      'edited_at': editedAtText(updatedAt ?? at, at),
  };
}
