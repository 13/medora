/// Medora - Attachment Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/attachment_import_result.dart';

abstract class AttachmentRepository {
  Future<Result<List<Attachment>>> forOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  );

  /// Stores [imported] as a new attachment of the owner; the file is
  /// written before the row, so a row never points at nothing here.
  Future<Result<Attachment>> add(
    AttachmentOwnerKind kind,
    String ownerId,
    Imported imported,
  );

  /// Tombstones the row, deletes the local file, and queues the storage
  /// object for removal when it was uploaded.
  Future<Result<void>> delete(String id);

  Future<Result<void>> deleteForOwner(AttachmentOwnerKind kind, String ownerId);

  /// Records a finished upload; refused (and the object queued for
  /// removal) when the attachment was deleted meanwhile.
  Future<Result<bool>> markUploaded(String id, String remotePath);
}
