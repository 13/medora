import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/sync_service.dart';

class SyncIconButton extends ConsumerWidget {
  const SyncIconButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncStateStreamProvider).value ?? SyncState.idle;
    final isSyncing = syncState == SyncState.syncing;

    return IconButton(
      icon: isSyncing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(
              syncState == SyncState.error ? Icons.sync_problem : Icons.sync,
              color: syncState == SyncState.error ? Colors.orange : null,
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
