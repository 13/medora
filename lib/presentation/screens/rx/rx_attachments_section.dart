/// Medora - Photos and PDFs attached to a prescription.
///
/// Picking goes through `attachment_picker.dart` (shared with the scan
/// sheet); [AttachmentImport] then strips EXIF and re-encodes every photo.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/attachment_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/rx/attachment_picker.dart';
import 'package:medora/presentation/screens/rx/attachment_viewer.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:open_filex/open_filex.dart';

enum _Source { camera, gallery, file }

/// Header, add button and thumbnail grid for one prescription's attachments.
class RxAttachmentsSection extends ConsumerStatefulWidget {
  const RxAttachmentsSection({super.key, required this.rxId});

  final String rxId;

  @override
  ConsumerState<RxAttachmentsSection> createState() =>
      _RxAttachmentsSectionState();
}

class _RxAttachmentsSectionState extends ConsumerState<RxAttachmentsSection> {
  bool _busy = false;

  (AttachmentOwnerKind, String) get _owner =>
      (AttachmentOwnerKind.rx, widget.rxId);

  void _invalidate() {
    ref.invalidate(attachmentsForOwnerProvider(_owner));
    ref.invalidate(attachmentCountsProvider);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _reportFailure() =>
      _showMessage(AppLocalizations.of(context).genericError);

  Future<void> _pickAndAdd(AttachmentPicker picker, _Source source) async {
    final pick = switch (source) {
      _Source.camera => picker.camera,
      _Source.gallery => picker.gallery,
      _Source.file => picker.file,
    };
    final ({String path, String? name})? picked;
    try {
      picked = await pick();
    } catch (_) {
      if (!mounted) return;
      _showMessage(AppLocalizations.of(context).genericError);
      return;
    }
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final ImportResult result;
      try {
        result = await ref.read(attachmentImportProvider)(
          picked.path,
          originalName: picked.name,
        );
      } catch (_) {
        if (!mounted) return;
        _showMessage(AppLocalizations.of(context).rxAttachmentUnreadable);
        return;
      }
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      switch (result) {
        case ImportRefused(:final reason):
          _showMessage(switch (reason) {
            ImportRefusal.tooLarge => l10n.rxAttachmentTooLarge,
            ImportRefusal.unsupported => l10n.rxAttachmentUnsupported,
            ImportRefusal.unreadable => l10n.rxAttachmentUnreadable,
          });
        case Imported():
          final addResult = await ref
              .read(attachmentRepositoryProvider)
              .add(AttachmentOwnerKind.rx, widget.rxId, result);
          if (!mounted) return;
          addResult.when(
            success: (_) {
              _invalidate();
              unawaited(ref.read(attachmentTransferProvider).run());
            },
            failure: (_) => _reportFailure(),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      // The import has read the file by now (success or not): drop our
      // own content-URI copy, or the platform picker's own cache copy,
      // now that nothing needs it.
      await cleanUpPickedFile(
        picked.path,
        picker: picker,
        viaFilePicker: source == _Source.file,
      );
    }
  }

  Future<void> _showAddSheet() async {
    final l10n = AppLocalizations.of(context);
    final hasCamera = ref.read(platformCapabilitiesProvider).hasCamera;
    final source = await showModalBottomSheet<_Source>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            if (hasCamera)
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: Text(l10n.rxAttachmentCamera),
                onTap: () => Navigator.pop(ctx, _Source.camera),
              ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.rxAttachmentGallery),
              onTap: () => Navigator.pop(ctx, _Source.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(l10n.rxAttachmentFile),
              onTap: () => Navigator.pop(ctx, _Source.file),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    await _pickAndAdd(ref.read(attachmentPickerProvider), source);
  }

  /// Deletes [a] and reports the real outcome regardless of whether this
  /// section is still mounted by the time the repository answers (the
  /// viewer may still be up on top of it and needs the true result to
  /// decide whether to pop); only the SnackBar/invalidation are UI work,
  /// so those stay behind the `mounted` guard.
  Future<bool> _delete(Attachment a) async {
    final result = await ref.read(attachmentRepositoryProvider).delete(a.id);
    if (mounted) {
      result.when(
        success: (_) => _invalidate(),
        failure: (_) => _reportFailure(),
      );
    }
    return result.isSuccess;
  }

  Future<void> _confirmDelete(Attachment a) async {
    if (!await confirmDeleteAttachment(context) || !mounted) return;
    await _delete(a);
  }

  Future<void> _open(Attachment a) async {
    final l10n = AppLocalizations.of(context);
    final file = await ref.read(attachmentTransferProvider).open(a);
    if (!mounted) return;
    if (file == null) {
      _showMessage(l10n.rxAttachmentNotAvailable);
      return;
    }
    if (a.kind == AttachmentKind.photo) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              AttachmentViewer(file: file, onDelete: () => _delete(a)),
        ),
      );
      return;
    }
    final result = await OpenFilex.open(file.path);
    if (!mounted) return;
    if (result.type != ResultType.done) _reportFailure();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final attachments = ref.watch(attachmentsForOwnerProvider(_owner));
    // Attachments are stored as files: without a file system (web) they
    // are listed, never added here.
    final canAdd = ref.watch(platformCapabilitiesProvider).hasFileSystem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l10n.rxAttachments,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Spacer(),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (canAdd)
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                tooltip: l10n.rxAttachmentAdd,
                onPressed: _showAddSheet,
              ),
          ],
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.rxAttachmentPreparing,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        attachments.when(
          data: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in list)
                      _Thumbnail(
                        key: ValueKey(a.id),
                        attachment: a,
                        onTap: () => _open(a),
                        onLongPress: () => _confirmDelete(a),
                      ),
                  ],
                ),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
          error: (_, _) => Text(l10n.genericError),
        ),
      ],
    );
  }
}

class _Thumbnail extends ConsumerStatefulWidget {
  const _Thumbnail({
    super.key,
    required this.attachment,
    required this.onTap,
    required this.onLongPress,
  });

  final Attachment attachment;
  final Future<void> Function() onTap;
  final VoidCallback onLongPress;

  @override
  ConsumerState<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends ConsumerState<_Thumbnail> {
  late Future<File?> _fileFuture = _resolve();

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same slot (same `ValueKey`) can end up pointing at a different
    // attachment (or the same one after a kind-affecting change); either
    // way the previously resolved file no longer applies.
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.kind != widget.attachment.kind) {
      setState(() {
        _fileFuture = _resolve();
      });
    }
  }

  /// Only a photo's thumbnail depends on the local file; skip the lookup
  /// for PDFs entirely, and everywhere without a file system (web).
  Future<File?> _resolve() async {
    if (widget.attachment.kind != AttachmentKind.photo) return null;
    if (!ref.read(platformCapabilitiesProvider).hasFileSystem) return null;
    final file = await ref
        .read(attachmentFilesProvider)
        .fileFor(widget.attachment);
    return file.existsSync() ? file : null;
  }

  Future<void> _handleTap() async {
    await widget.onTap();
    // A tap may have just downloaded the file (or deleted the attachment
    // outright); either way, re-resolve so the thumbnail reflects it.
    if (!mounted) return;
    setState(() {
      _fileFuture = _resolve();
    });
  }

  Widget _placeholder(IconData icon) => Container(
    width: 72,
    height: 72,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(icon),
  );

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: _handleTap,
    onLongPress: widget.onLongPress,
    child: SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FutureBuilder<File?>(
            future: _fileFuture,
            builder: (context, snapshot) {
              if (widget.attachment.kind == AttachmentKind.photo) {
                final file = snapshot.data;
                if (file != null) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(
                      file,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      cacheWidth: 216,
                      errorBuilder: (context, error, stackTrace) =>
                          _placeholder(Icons.broken_image_outlined),
                    ),
                  );
                }
                return _placeholder(Icons.cloud_outlined);
              }
              return _placeholder(Icons.picture_as_pdf_outlined);
            },
          ),
          if (widget.attachment.kind == AttachmentKind.pdf)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.attachment.originalName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    ),
  );
}
