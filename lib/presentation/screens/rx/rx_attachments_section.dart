/// Medora - Photos and PDFs attached to a prescription.
///
/// A camera/gallery pick is downscaled natively (`ImagePicker`'s
/// `maxWidth`/`maxHeight`/`imageQuality`) mostly to keep the raw bytes
/// manageable on a high-megapixel camera; [AttachmentImport] still strips
/// EXIF and re-encodes every photo regardless of where it came from, so
/// this is a size optimisation, not the place import rules live.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/attachment_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/rx/attachment_viewer.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// What the section needs from the platform to obtain a picked file's path
/// (and, for the file picker, its original name) — kept as a port so
/// widget tests can supply a fake instead of driving platform channels.
abstract interface class AttachmentPicker {
  Future<({String path, String? name})?> camera();
  Future<({String path, String? name})?> gallery();
  Future<({String path, String? name})?> file(); // pdf, jpg, jpeg, png
}

class PlatformAttachmentPicker implements AttachmentPicker {
  const PlatformAttachmentPicker();

  /// The device's own camera/gallery downscale (see the library doc); the
  /// import pipeline resizes and re-encodes regardless.
  static const _maxDimension = 2400.0;
  static const _imageQuality = 95;

  @override
  Future<({String path, String? name})?> camera() =>
      _fromImagePicker(ImageSource.camera);

  @override
  Future<({String path, String? name})?> gallery() =>
      _fromImagePicker(ImageSource.gallery);

  Future<({String path, String? name})?> _fromImagePicker(
    ImageSource source,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: _maxDimension,
      maxHeight: _maxDimension,
      imageQuality: _imageQuality,
    );
    if (picked == null) return null;
    return (path: picked.path, name: picked.name);
  }

  @override
  Future<({String path, String? name})?> file() async {
    final picked = await fp.FilePicker.pickFile(
      type: fp.FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (picked == null) return null;
    final existingPath = picked.path;
    if (existingPath != null) return (path: existingPath, name: picked.name);

    // Some Android providers hand back a content URI with no path on disk;
    // copy the bytes into the cache so the import sees a real file (as
    // `pickBackupFile` does for the backup restore flow).
    final cache = await getTemporaryDirectory();
    final copy = File(path.join(cache.path, path.basename(picked.name)));
    await copy.writeAsBytes(await picked.readAsBytes(), flush: true);
    return (path: copy.path, name: picked.name);
  }
}

final attachmentPickerProvider = Provider<AttachmentPicker>(
  (_) => const PlatformAttachmentPicker(),
);

/// Preparing a picked file, as a provider — so widget tests can swap in a
/// synchronous stand-in. [AttachmentImport.fromPath] runs the real decode
/// on a background isolate via `compute`, which never returns under
/// `testWidgets`'s fake-async test binding.
typedef AttachmentImporter =
    Future<ImportResult> Function(String path, {String? originalName});

final attachmentImportProvider = Provider<AttachmentImporter>(
  (_) => AttachmentImport.fromPath,
);

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

  Future<void> _pickAndAdd(
    Future<({String path, String? name})?> Function() pick,
  ) async {
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
    final picker = ref.read(attachmentPickerProvider);
    switch (source) {
      case _Source.camera:
        await _pickAndAdd(picker.camera);
      case _Source.gallery:
        await _pickAndAdd(picker.gallery);
      case _Source.file:
        await _pickAndAdd(picker.file);
    }
  }

  Future<bool> _delete(Attachment a) async {
    final result = await ref.read(attachmentRepositoryProvider).delete(a.id);
    if (!mounted) return false;
    return result.when(
      success: (_) {
        _invalidate();
        return true;
      },
      failure: (_) {
        _reportFailure();
        return false;
      },
    );
  }

  Future<void> _confirmDelete(Attachment a) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.rxAttachmentDelete),
        content: Text(l10n.rxAttachmentDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
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
            else
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
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  ConsumerState<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends ConsumerState<_Thumbnail> {
  late final Future<File?> _fileFuture = _resolve();

  Future<File?> _resolve() async {
    final file = await ref
        .read(attachmentFilesProvider)
        .fileFor(widget.attachment);
    return file.existsSync() ? file : null;
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
    onTap: widget.onTap,
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
