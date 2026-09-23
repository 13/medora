/// Medora - Attachment Repository Implementation (offline-first).
///
/// Same rules as the other repositories: write locally as pending, then ask
/// for a sync cycle, which is the only push path. The bytes live in a file
/// named after the attachment's id ([AttachmentFiles]); a row never points
/// at a missing file, because [add] writes the file first and rolls it back
/// if the row write fails.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/attachment_import_result.dart';
import 'package:medora/domain/repositories/attachment_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class AttachmentRepositoryImpl implements AttachmentRepository {
  AttachmentRepositoryImpl({
    required this.local,
    required this.files,
    this._requestSync,
    this._now = systemNow,
  });

  final AttachmentLocalDatasource local;
  final AttachmentFiles files;
  final RequestSync? _requestSync;
  final Now _now;

  static const _uuid = Uuid();

  @override
  Future<Result<List<Attachment>>> forOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async {
    try {
      final rows = await local.getForOwner(kind, ownerId);
      return Result.success([for (final r in rows) r.toDomain()]);
    } catch (e, st) {
      return Result.failure('Failed to load attachments: $e', st);
    }
  }

  @override
  Future<Result<Attachment>> add(
    AttachmentOwnerKind kind,
    String ownerId,
    Imported imported,
  ) async {
    try {
      final now = _now();
      final attachment = Attachment(
        id: _uuid.v4(),
        // userId is left null; the sync stamps the owning user once it
        // pushes the row.
        ownerKind: kind,
        ownerId: ownerId,
        kind: imported.kind,
        mime: imported.mime,
        sizeBytes: imported.bytes.length,
        sha256: imported.sha256,
        originalName: imported.originalName,
        createdAt: now,
        updatedAt: now,
      );
      try {
        await files.write(attachment.fileName, imported.bytes);
      } catch (e, st) {
        return Result.failure('Failed to store the attachment file: $e', st);
      }
      try {
        await local.upsert(
          AttachmentModel.fromDomain(attachment),
          syncStatus: SyncStatus.pendingCreate,
        );
      } catch (e, st) {
        // The file must never outlive the row that points at it.
        await files.delete(attachment.fileName);
        return Result.failure('Failed to save the attachment: $e', st);
      }
      _syncSoon();
      return Result.success(attachment);
    } catch (e, st) {
      return Result.failure('Failed to add the attachment: $e', st);
    }
  }

  @override
  Future<Result<void>> delete(String id) async {
    try {
      final row = await local.getById(id);
      if (row == null || row.deletedAt != null) {
        return const Result.failure('Attachment not found');
      }
      await _tombstone(row);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete the attachment: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteForOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async {
    try {
      for (final row in await local.getForOwner(kind, ownerId)) {
        await _tombstone(row);
      }
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete the attachments: $e', st);
    }
  }

  /// Tombstones [row]'s local row, then removes its file: a failure there
  /// only logs (by exception type — never the path) and does not fail the
  /// delete, since the orphan sweep removes it later. The removal is queued
  /// only when the object was actually uploaded.
  Future<void> _tombstone(AttachmentModel row) async {
    await local.markDeleted(row.id);
    try {
      await files.delete(row.toDomain().fileName);
    } catch (e) {
      debugPrint('Attachment: file delete failed: ${e.runtimeType}');
    }
    final remotePath = row.remotePath;
    if (remotePath != null) {
      await local.enqueueRemoval(remotePath);
    }
  }

  @override
  Future<Result<bool>> markUploaded(String id, String remotePath) async {
    try {
      final row = await local.getById(id);
      if (row != null && p.basename(remotePath) != row.toDomain().fileName) {
        return const Result.failure('Attachment path does not match');
      }
      // One conditional write: a delete landing after the read above must
      // not be overwritten by a live row. A row deleted meanwhile, or gone
      // altogether (hard-deleted after its tombstone synced, or wiped), has
      // nothing to point at any more, so the object that just finished
      // uploading is queued for removal instead. Writing pendingUpdate on a
      // never-pushed row is safe because sync_version == null is treated as
      // a create (TableSync.pushRow → _pushCreate).
      final recorded = await local.setRemotePathIfLive(
        id,
        remotePath,
        updatedAt: (stored) => nextUpdatedAt(stored, _now()),
      );
      if (recorded) _syncSoon();
      return Result.success(recorded);
    } catch (e, st) {
      return Result.failure('Failed to record the upload: $e', st);
    }
  }

  void _syncSoon() => requestSyncSoon(_requestSync, 'attachment');
}
