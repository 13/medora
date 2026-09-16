/// Medora - Add/Edit Medication: the photo picker.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';

/// The medication photo: the saved image, or a placeholder that opens the
/// picker, plus a delete action once there is one.
class MedicationPhotoSection extends ConsumerWidget {
  const MedicationPhotoSection({
    super.key,
    required this.imagePath,
    required this.onPick,
    required this.onDelete,
  });

  /// The stored photo's file name, or null while there is none.
  final String? imagePath;
  final VoidCallback onPick;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.medicationPhoto,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onPick,
          child: Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.colors.outlineVariant),
            ),
            child: imagePath == null || kIsWeb
                ? _placeholder(context, l10n)
                : ref
                      .watch(resolvedPhotoProvider(imagePath))
                      .maybeWhen(
                        data: (file) {
                          if (file == null) return _placeholder(context, l10n);
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              file,
                              fit: BoxFit.cover,
                              width: double.infinity,
                            ),
                          );
                        },
                        orElse: () => _placeholder(context, l10n),
                      ),
          ),
        ),
        if (imagePath != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l10n.delete),
            ),
          ),
        ],
      ],
    );
  }
}

Widget _placeholder(BuildContext context, AppLocalizations l10n) {
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.add_a_photo, size: 40, color: context.colors.outline),
      const SizedBox(height: 8),
      Text(l10n.addPhoto, style: TextStyle(color: context.colors.outline)),
    ],
  );
}
