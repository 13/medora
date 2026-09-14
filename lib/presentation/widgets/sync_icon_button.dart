import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/sync_service.dart';

class SyncIconButton extends ConsumerWidget {
  const SyncIconButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(appModeProvider) != AppMode.cloud) return const SizedBox.shrink();
    final syncState = ref.watch(syncStateStreamProvider).value ?? SyncState.idle;
    final isSyncing = syncState == SyncState.syncing;

    return IconButton(
      icon: isSyncing
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.colors.onSurface,
              ),
            )
          : Icon(
              syncState == SyncState.error ? Icons.sync_problem : Icons.sync,
              color: syncState == SyncState.error ? context.medora.danger : null,
            ),
      onPressed: isSyncing
          ? null
          : () {
              ref.read(syncServiceProvider).syncAll();
            },
      tooltip: isSyncing ? 'Syncing...' : 'Sync now',
    );
  }
}
