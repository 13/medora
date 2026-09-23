/// Medora - Attachment Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:sqflite/sqflite.dart';

class AttachmentLocalDatasource {
  AttachmentLocalDatasource({Now now = systemNow})
    : _now = now,
      _table = SyncedLocalTable<AttachmentModel>(
        table: 'attachments',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: AttachmentModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final Now _now;
  final SyncedLocalTable<AttachmentModel> _table;

  Future<Database> get _db => AppDatabase.instance.database;

  Future<void> upsert(AttachmentModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);

  Future<AttachmentModel?> getById(String id) => _table.getById(id);

  Future<List<AttachmentModel>> getForOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) => _table.getAll(
    where: 'owner_kind = ? AND owner_id = ?',
    whereArgs: [kind.wire, ownerId],
    orderBy: 'created_at',
  );

  Future<List<AttachmentModel>> getAwaitingUpload() =>
      _table.getAll(where: 'remote_path IS NULL', orderBy: 'created_at');

  Future<List<String>> getAllIds() async => [
    for (final r in await (await _db).query('attachments', columns: ['id']))
      r['id']! as String,
  ];

  Future<void> enqueueRemoval(String remotePath) async => (await _db).insert(
    'attachment_removals',
    {'remote_path': remotePath, 'created_at': _now().toIso8601String()},
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  Future<List<String>> pendingRemovals() async => [
    for (final r in await (await _db).query(
      'attachment_removals',
      orderBy: 'created_at, remote_path',
    ))
      r['remote_path']! as String,
  ];

  Future<void> completeRemoval(String remotePath) async => (await _db).delete(
    'attachment_removals',
    where: 'remote_path = ?',
    whereArgs: [remotePath],
  );

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      AttachmentModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    AttachmentModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      ...m.toJson(),
      ...SyncedLocalTable.rowStamps(
        m.createdAt,
        m.updatedAt,
        m.deletedAt,
        syncStatus,
        at,
      ),
    };
  }
}
