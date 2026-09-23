/// Medora - A controllable [AttachmentRepository] fake for widget tests,
/// so they never touch the real sqlite-backed implementation.
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/attachment_import_result.dart';
import 'package:medora/domain/repositories/attachment_repository.dart';

class FakeAttachmentRepository implements AttachmentRepository {
  FakeAttachmentRepository({List<Attachment> attachments = const []})
    : attachments = [...attachments];

  final List<Attachment> attachments;

  /// Overrides what [add] returns; null means "succeed and append a new
  /// attachment built from the imported bytes".
  Result<Attachment>? addResult;

  /// What [delete] returns; a success also removes the id from
  /// [attachments].
  Result<void> deleteResult = const Result.success(null);

  final added = <Imported>[];
  final deletedIds = <String>[];

  @override
  Future<Result<List<Attachment>>> forOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async => Result.success([
    for (final a in attachments)
      if (a.ownerKind == kind && a.ownerId == ownerId) a,
  ]);

  @override
  Future<Result<Attachment>> add(
    AttachmentOwnerKind kind,
    String ownerId,
    Imported imported,
  ) async {
    added.add(imported);
    final result = addResult;
    if (result != null) return result;
    final a = Attachment(
      id: 'a${added.length}',
      ownerKind: kind,
      ownerId: ownerId,
      kind: imported.kind,
      mime: imported.mime,
      sizeBytes: imported.bytes.length,
      sha256: imported.sha256,
      originalName: imported.originalName,
    );
    attachments.add(a);
    return Result.success(a);
  }

  @override
  Future<Result<void>> delete(String id) async {
    deletedIds.add(id);
    if (deleteResult.isSuccess) attachments.removeWhere((a) => a.id == id);
    return deleteResult;
  }

  @override
  Future<Result<void>> deleteForOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) async {
    attachments.removeWhere((a) => a.ownerKind == kind && a.ownerId == ownerId);
    return const Result.success(null);
  }

  @override
  Future<Result<bool>> markUploaded(
    String id,
    String remotePath, {
    required String? signedInUserId,
  }) async => const Result.success(true);

  @override
  Future<Result<Map<String, int>>> countsForKind(
    AttachmentOwnerKind kind,
  ) async {
    final counts = <String, int>{};
    for (final a in attachments) {
      if (a.ownerKind != kind) continue;
      counts[a.ownerId] = (counts[a.ownerId] ?? 0) + 1;
    }
    return Result.success(counts);
  }
}
