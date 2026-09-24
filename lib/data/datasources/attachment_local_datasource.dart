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

  /// Every live row of [kind], across all owners — one query, for callers
  /// that need counts per owner without a query per owner.
  Future<List<AttachmentModel>> getForKind(AttachmentOwnerKind kind) =>
      _table.getAll(where: 'owner_kind = ?', whereArgs: [kind.wire]);

  Future<List<AttachmentModel>> getAwaitingUpload() =>
      _table.getAll(where: 'remote_path IS NULL', orderBy: 'created_at');

  Future<List<String>> getAllIds() async => [
    for (final r in await (await _db).query('attachments', columns: ['id']))
      r['id']! as String,
  ];

  /// Records the upload of [id] at [remotePath] as a pending update, in one
  /// transaction with the check that the row is still live and that
  /// [remotePath] lies in its owner's folder: the row's `user_id`, or
  /// [signedInUserId] when the row has none. When it is gone, deleted or
  /// owned by another account (a sign-out and sign-in while the upload
  /// ran), [remotePath] is queued for removal instead (same transaction)
  /// and the result is false. [updatedAt] gives the new `updated_at` from
  /// the stored one.
  Future<bool> setRemotePathIfLive(
    String id,
    String remotePath, {
    required String? signedInUserId,
    required DateTime Function(DateTime? stored) updatedAt,
  }) async => (await _db).transaction((txn) async {
    final owner = await txn.query(
      'attachments',
      columns: ['user_id'],
      where: 'id = ?',
      whereArgs: [id],
    );
    final folder = owner.isEmpty
        ? null
        : (owner.single['user_id'] as String?) ?? signedInUserId;
    final recorded =
        folder != null &&
        remotePath.startsWith('$folder/') &&
        await _table.updateLiveIn(
          txn,
          id,
          (m) => m.copyWith(
            remotePath: remotePath,
            updatedAt: updatedAt(m.updatedAt),
          ),
          syncStatus: SyncStatus.pendingUpdate,
        );
    if (!recorded) await _enqueueRemoval(txn, remotePath);
    return recorded;
  });

  Future<void> enqueueRemoval(String remotePath) async =>
      _enqueueRemoval(await _db, remotePath);

  Future<void> _enqueueRemoval(DatabaseExecutor db, String remotePath) =>
      enqueueRemovalIn(db, remotePath, at: _now());

  /// Queues [remotePath] for removal from storage through [db] (a
  /// transaction of the caller's); a path already queued stays as it was.
  static Future<void> enqueueRemovalIn(
    DatabaseExecutor db,
    String remotePath, {
    required DateTime at,
  }) => db.insert('attachment_removals', {
    'remote_path': remotePath,
    'created_at': at.toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Queues the objects of the attachment [rows] (local rows, about to be
  /// deleted here without a person's delete: a sync or a remote wipe) for
  /// removal, those in [userId]'s folder only: another account's objects
  /// are not this one's to remove, and would stay queued for good. Nothing
  /// is queued without a signed-in [userId].
  static Future<void> enqueueOwnRemovalsIn(
    DatabaseExecutor db,
    Iterable<Map<String, Object?>> rows, {
    required String? userId,
    required DateTime at,
  }) async {
    if (userId == null) return;
    for (final row in rows) {
      final path = row['remote_path'];
      if (path is String && path.startsWith('$userId/')) {
        await enqueueRemovalIn(db, path, at: at);
      }
    }
  }

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
