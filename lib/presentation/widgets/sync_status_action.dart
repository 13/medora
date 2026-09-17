/// Medora - The Dashboard's sync status, as an app-bar icon (cloud mode only).
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
/// An icon, not a labelled chip: app-bar actions are neither width-limited
/// nor text-scale-clamped, and the German and Italian labels ("Synchroni-
/// sierung fehlgeschlagen — tippen zum Wiederholen") pushed the settings gear
/// off screen and squeezed the title to nothing at the default text size.
/// The status text lives in the tooltip, which is also the screen-reader
/// label. Each state has its own icon, so colour is never the only cue.
///
/// Hidden entirely outside cloud mode.
class SyncStatusAction extends ConsumerWidget {
  const SyncStatusAction({super.key});

  /// The button's own key, for tests.
  static const buttonKey = Key('syncStatusAction');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(appModeProvider) != AppMode.cloud) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final syncState =
        ref.watch(syncStateStreamProvider).value ?? SyncState.idle;

    final (Widget icon, String label) = switch (syncState) {
      SyncState.syncing => (
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: context.colors.onSurfaceVariant,
          ),
        ),
        l10n.syncing,
      ),
      SyncState.error => (
        Icon(Icons.sync_problem, color: context.medora.danger),
        l10n.syncError,
      ),
      SyncState.partial => (
        Icon(Icons.warning_amber_rounded, color: context.medora.warning),
        l10n.syncPartial,
      ),
      SyncState.idle || SyncState.success => (
        const Icon(Icons.cloud_done_outlined),
        l10n.syncNow,
      ),
    };

    return IconButton(
      key: buttonKey,
      icon: icon,
      tooltip: label,
      onPressed: syncState == SyncState.syncing
          ? null
          : () => ref.read(syncServiceProvider).syncAll(),
    );
  }
}
