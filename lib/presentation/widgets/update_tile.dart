/// Medora - The "Check for updates" tile in Settings → About.
///
/// Tapping it forces a check (the 24 h throttle is for the automatic startup
/// check, not for a user who asks); once a release is known the tap opens
/// [UpdateSheet] instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_config_provider.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/widgets/update_sheet.dart';

class UpdateTile extends ConsumerWidget {
  const UpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(platformCapabilitiesProvider).hasInAppUpdates ||
        !ref.watch(appConfigProvider).hasInAppUpdates) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final status = ref.watch(appUpdateProvider).value ?? const UpdateUnknown();
    final busy = status is UpdateChecking || status is UpdateDownloading;

    final subtitle = switch (status) {
      UpdateUnknown() => null,
      UpdateChecking() => l10n.checkingForUpdates,
      UpdateUpToDate() => l10n.upToDate,
      UpdateAvailable(:final release) ||
      UpdateDownloading(:final release) ||
      UpdateReady(
        :final release,
      ) => l10n.updateAvailable(release.version.label),
      UpdateFailed(:final error) => updateErrorMessage(l10n, error),
    };

    final hasRelease = updateTagOf(status) != null;
    return ListTile(
      leading: const Icon(Icons.system_update),
      title: Text(l10n.checkForUpdates),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: busy
          ? null
          : () {
              if (hasRelease) {
                showUpdateSheet(context);
              } else {
                ref.read(appUpdateProvider.notifier).check(force: true);
              }
            },
    );
  }
}
