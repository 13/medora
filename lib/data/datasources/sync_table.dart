/// Medora - The server side of one synced table (sync v2).
///
/// The four synced tables (medications, treatments, prescriptions, dose
/// logs) are read and written the same way, so one class does it for each.
/// The rows go in and out as JSON maps: the model's `toJson` keys plus the
/// server's bookkeeping ([RemoteMeta]).
library;

import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The server's bookkeeping on a synced row (migration 20260918000000).
class RemoteMeta {
  const RemoteMeta({
    required this.syncXid,
    required this.rowVersion,
    this.writeId,
    this.editedAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory RemoteMeta.fromJson(Map<String, dynamic> json) => RemoteMeta(
    syncXid: (json['sync_xid'] as num?)?.toInt() ?? 0,
    rowVersion: (json['row_version'] as num?)?.toInt() ?? 1,
    writeId: json['write_id'] as String?,
    editedAt: _time(json['edited_at']),
    updatedAt: _time(json['updated_at']),
    deletedAt: _time(json['deleted_at']),
  );

  final int syncXid;
  final int rowVersion;

  /// The write attempt that produced this copy; null for a writer that sends
  /// none (Medora 0.3.0, the tombstone cascade).
  final String? writeId;

  /// When the change was made; 1970 for a change the app made on its own.
  /// Null only for rows untouched since the migration: read [updatedAt].
  final DateTime? editedAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// [editedAt], or [updatedAt] for a row from before the migration.
  DateTime? get effectiveEditedAt => editedAt ?? updatedAt;

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

/// One synced table on the server.
abstract interface class SyncTable {
  /// One page of rows below [horizon] after [after] (see `pullPage`),
  /// tombstones included.
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  });

  /// The row with [id], tombstone included, or null.
  Future<Map<String, dynamic>?> fetch(String id);

  /// The rows with these [ids]; ids the server lacks are absent.
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids);

  /// Updates the row [id] with [changes] when it is still at [ifVersion]
  /// (any version when null), `status` equals [ifStatus] (when set) and,
  /// with [ifLive], it is not deleted. Returns the row as written, or null
  /// when no row matched.
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  });

  /// Inserts [rows], leaving every id the server already has untouched
  /// (`ON CONFLICT (id) DO NOTHING`). Every row must have the same keys.
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows);
}

/// [SyncTable] over PostgREST.
class PostgrestSyncTable implements SyncTable {
  /// [select] must start with `*`, so the bookkeeping columns come along.
  /// A write the server refuses for a column it lacks becomes a
  /// [MissingColumnException] naming [migration] ([fallbackColumn] when the
  /// server names none).
  PostgrestSyncTable(
    this._client,
    this.table, {
    String select = '*',
    this.migration,
    this.fallbackColumn,
  }) : assert(select.startsWith('*'), 'select must include every column'),
       _select = select;

  final SupabaseClient _client;
  final String table;
  final String _select;
  final String? migration;
  final String? fallbackColumn;

  Future<T> _write<T>(Future<T> Function() send) {
    final file = migration;
    if (file == null) return send();
    return mapMissingColumn(
      send,
      table: table,
      migration: file,
      fallbackColumn: fallbackColumn ?? 'id',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) async => pullPage(
    _client.from(table).select(_select),
    after: after,
    horizon: horizon,
  );

  @override
  Future<Map<String, dynamic>?> fetch(String id) =>
      _client.from(table).select(_select).eq('id', id).maybeSingle();

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    if (ids.isEmpty) return const [];
    return _client.from(table).select(_select).inFilter('id', ids);
  }

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    return _write(() async {
      var query = _client.from(table).update(changes).eq('id', id);
      if (ifVersion != null) query = query.eq('row_version', ifVersion);
      if (ifStatus != null) query = query.eq('status', ifStatus);
      if (ifLive) query = query.isFilter('deleted_at', null);
      final rows = await query.select(_select);
      return rows.isEmpty ? null : rows.first;
    });
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _write(
      () => _client
          .from(table)
          .upsert(rows, onConflict: 'id', ignoreDuplicates: true),
    );
  }
}
