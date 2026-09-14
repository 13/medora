/// Medora - Sync status chip for the Home AppBar (cloud mode only).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/sync_service.dart';

/// Shows the current cloud sync state and lets the user trigger a sync.
///
/// Hidden entirely outside cloud mode.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(appModeProvider) != AppMode.cloud)
      return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final syncState =
        ref.watch(syncStateStreamProvider).value ?? SyncState.idle;
    final isSyncing = syncState == SyncState.syncing;
    final isError = syncState == SyncState.error;
    final isPartial = syncState == SyncState.partial;

    final Widget avatar;
    final String label;
    if (isSyncing) {
      avatar = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.colors.onSurfaceVariant,
        ),
      );
      label = l10n.syncing;
    } else if (isError) {
      avatar = Icon(
        Icons.warning_amber_rounded,
        size: 18,
        color: context.medora.danger,
      );
      label = l10n.syncError;
    } else if (isPartial) {
      avatar = Icon(
        Icons.warning_amber_rounded,
        size: 18,
        color: context.medora.warning,
      );
      label = l10n.syncPartial;
    } else {
      avatar = Icon(
        Icons.cloud_done_outlined,
        size: 18,
        color: context.colors.onSurfaceVariant,
      );
      label = l10n.syncNow;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ActionChip(
        avatar: avatar,
        label: Text(label),
        onPressed: isSyncing
            ? null
            : () => ref.read(syncServiceProvider).syncAll(),
      ),
    );
  }
}
