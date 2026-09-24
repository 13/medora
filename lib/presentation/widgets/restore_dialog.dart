/// Medora - Confirming a restore from a backup file.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/backup_service.dart';

/// Shows what [manifest] holds and asks how to apply it.
/// Returns the chosen mode, or null when the user backs out.
Future<RestoreMode?> showRestoreDialog(
  BuildContext context,
  BackupManifest manifest,
) => showDialog<RestoreMode>(
  context: context,
  builder: (_) => RestoreDialog(manifest: manifest),
);

class RestoreDialog extends StatefulWidget {
  const RestoreDialog({required this.manifest, super.key});

  final BackupManifest manifest;

  @override
  State<RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<RestoreDialog> {
  RestoreMode _mode = RestoreMode.replace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final manifest = widget.manifest;

    return AlertDialog(
      title: Text(l10n.restoreBackup),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                l10n.restoreSummary(
                  manifest.createdAt.toLocal().dateTimeFormatted,
                  manifest.totalRows,
                  manifest.photoCount,
                ),
                if (manifest.attachmentFileCount > 0)
                  l10n.restoreAttachmentFiles(manifest.attachmentFileCount),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (manifest.appVersion.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  manifest.appVersion,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            RadioGroup<RestoreMode>(
              groupValue: _mode,
              onChanged: (mode) => setState(() => _mode = mode ?? _mode),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<RestoreMode>(
                    value: RestoreMode.replace,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.restoreReplace),
                  ),
                  RadioListTile<RestoreMode>(
                    value: RestoreMode.merge,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.restoreMerge),
                  ),
                ],
              ),
            ),
            if (_mode == RestoreMode.replace)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 18,
                    color: context.medora.warning,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.restoreReplaceWarning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.medora.warning,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _mode),
          child: Text(l10n.restoreAction),
        ),
      ],
    );
  }
}
