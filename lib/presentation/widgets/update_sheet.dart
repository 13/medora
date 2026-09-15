/// Medora - The update details sheet.
///
/// Opened from the Settings tile and the Home banner. It is the only place
/// that starts a download, so the buttons follow the state machine directly:
/// Download -> progress -> Install, with "Later" dismissing the release.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/services/app_update_service.dart';

/// Opens [UpdateSheet] as a modal bottom sheet.
Future<void> showUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const UpdateSheet(),
  );
}

/// The message for an [UpdateException] - the kinds the user can act on get
/// their own wording, everything else is a generic failure.
String updateErrorMessage(AppLocalizations l10n, UpdateException error) =>
    switch (error.kind) {
      UpdateErrorKind.checksum => l10n.updateChecksumFailed,
      UpdateErrorKind.noAsset => l10n.updateNoAsset,
      _ => l10n.updateFailed,
    };

class UpdateSheet extends ConsumerWidget {
  const UpdateSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(appUpdateProvider).value ?? const UpdateUnknown();
    final release = switch (status) {
      UpdateAvailable(:final release) => release,
      UpdateDownloading(:final release) => release,
      UpdateReady(:final release) => release,
      _ => null,
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (release != null) ...[
              Text(release.title, style: context.text.titleLarge),
              const SizedBox(height: 4),
              Text(
                release.version.label,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              if (release.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l10n.updateReleaseNotes, style: context.text.titleSmall),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      release.notes.trim(),
                      style: context.text.bodyMedium,
                    ),
                  ),
                ),
              ],
            ],
            if (status is UpdateFailed) ...[
              const SizedBox(height: 16),
              Text(
                updateErrorMessage(l10n, status.error),
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.error,
                ),
              ),
            ],
            if (status is UpdateDownloading) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(value: status.progress),
            ],
            const SizedBox(height: 24),
            _Actions(status: status),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.status});

  final UpdateStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(appUpdateProvider.notifier);

    Future<void> later() async {
      await notifier.dismiss();
      if (context.mounted) await Navigator.of(context).maybePop();
    }

    // A download in flight offers no buttons at all: cancelling mid-stream
    // is not supported, and "Later" would leave a half-written file behind.
    if (status is UpdateDownloading) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(onPressed: later, child: Text(l10n.updateLater)),
        const SizedBox(width: 8),
        if (status is UpdateReady)
          FilledButton(
            onPressed: notifier.install,
            child: Text(l10n.updateInstall),
          )
        else if (status is UpdateAvailable)
          FilledButton(
            onPressed: notifier.download,
            child: Text(l10n.updateDownload),
          ),
      ],
    );
  }
}
