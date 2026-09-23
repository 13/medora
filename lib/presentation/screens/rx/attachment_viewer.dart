/// Medora - Full-screen viewer for a photo attachment.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Confirms before deleting an attachment; shared by this viewer's own
/// delete button and the attachments section's long-press delete, so both
/// entry points show the same dialog.
Future<bool> confirmDeleteAttachment(BuildContext context) async {
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
  return confirmed ?? false;
}

/// Shows [file] pinch-to-zoomable on black, with a close button and,
/// when [onDelete] is given, a delete button. [onDelete] does the actual
/// repository delete (and invalidation) and returns whether it succeeded;
/// the viewer pops only on success. On failure the caller has already
/// shown a SnackBar, so this widget never shows one of its own.
class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({super.key, required this.file, this.onDelete});

  final File file;
  final Future<bool> Function()? onDelete;

  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  bool _deleting = false;

  Future<void> _delete() async {
    if (!await confirmDeleteAttachment(context) || !mounted) return;
    setState(() => _deleting = true);
    final ok = await widget.onDelete!.call();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    // A failure's SnackBar is the caller's job (see the class doc); this
    // widget only stops its own spinner.
    setState(() => _deleting = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (widget.onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.rxAttachmentDelete,
              onPressed: _deleting ? null : _delete,
            ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Image.file(
            widget.file,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
