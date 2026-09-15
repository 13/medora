/// Medora - Asking whether a backup should carry the medication photos.
///
/// The export holds the whole envelope in memory before it is written, and
/// base64 grows the photos by about a third, so a photo-heavy cabinet is the
/// one thing that can make a backup too big for the device to handle. The
/// choice is surfaced instead of being decided silently.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/backup_service.dart';

/// Asks whether the photos go into the backup.
///
/// Returns the answer, or null when the user backs out. The box starts ticked
/// unless the photos are larger than [BackupService.largePhotoBytes].
Future<bool?> showBackupPhotosDialog(
  BuildContext context, {
  required int photoCount,
  required int photoBytes,
}) => showDialog<bool>(
  context: context,
  builder: (_) =>
      BackupPhotosDialog(photoCount: photoCount, photoBytes: photoBytes),
);

class BackupPhotosDialog extends StatefulWidget {
  const BackupPhotosDialog({
    required this.photoCount,
    required this.photoBytes,
    super.key,
  });

  final int photoCount;
  final int photoBytes;

  /// True when the photos are big enough that including them is a bad default.
  bool get isLarge => photoBytes > BackupService.largePhotoBytes;

  @override
  State<BackupPhotosDialog> createState() => _BackupPhotosDialogState();
}

class _BackupPhotosDialogState extends State<BackupPhotosDialog> {
  late bool _includePhotos = !widget.isLarge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;

    return AlertDialog(
      title: Text(l10n.backupData),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: _includePhotos,
            contentPadding: EdgeInsets.zero,
            onChanged: (value) =>
                setState(() => _includePhotos = value ?? _includePhotos),
            title: Text(
              l10n.backupIncludePhotos(
                widget.photoCount,
                _megabytes(widget.photoBytes),
              ),
            ),
          ),
          if (widget.isLarge)
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
                    l10n.backupPhotosTooLarge,
                    style: text.bodySmall?.copyWith(
                      color: context.medora.warning,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _includePhotos),
          child: Text(l10n.backupAction),
        ),
      ],
    );
  }

  /// The payload in megabytes, with one decimal while that still says
  /// something. The unit itself lives in the translated string.
  String _megabytes(int bytes) {
    final megabytes = bytes / (1024 * 1024);
    return NumberFormat.decimalPatternDigits(
      decimalDigits: megabytes >= 10 ? 0 : 1,
    ).format(megabytes);
  }
}
