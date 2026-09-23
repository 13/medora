/// Medora - What the screens show of attachments.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/presentation/providers/providers.dart';

final attachmentsForOwnerProvider =
    FutureProvider.family<List<Attachment>, (AttachmentOwnerKind, String)>((
      ref,
      owner,
    ) async {
      final result = await ref
          .watch(attachmentRepositoryProvider)
          .forOwner(owner.$1, owner.$2);
      return result.when(success: (a) => a, failure: (m) => throw Exception(m));
    });
