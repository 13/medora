/// Medora - Home banner for a pending update.
///
/// Renders nothing unless a newer release is known and the user has not
/// dismissed that exact tag, so Home stays unchanged in the common case.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/widgets/update_sheet.dart';

class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appUpdateProvider).value;
    final release = switch (status) {
      UpdateAvailable(:final release) => release,
      UpdateReady(:final release) => release,
      _ => null,
    };
    if (release == null) return const SizedBox.shrink();
    if (ref.watch(updateDismissedTagProvider) == release.tag) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: context.colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update,
              size: 20,
              color: context.colors.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.updateBannerTitle(release.version.label),
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onPrimaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => showUpdateSheet(context),
              child: Text(l10n.updateView),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              iconSize: 20,
              tooltip: l10n.updateLater,
              color: context.colors.onPrimaryContainer,
              onPressed: () => ref.read(appUpdateProvider.notifier).dismiss(),
            ),
          ],
        ),
      ),
    );
  }
}
