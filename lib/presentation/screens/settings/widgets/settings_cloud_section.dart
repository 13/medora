/// Medora - Settings → Cloud sync: the account, the sync state and the
/// force push/pull actions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_dialogs.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/presentation/widgets/cloud_config_sheet.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/sync_service.dart';

/// The Cloud sync group: whether the cloud is configured and on, the
/// connection and sync state, the last cycle's report, and (behind
/// "Advanced") the two force-sync actions.
class SettingsCloudSection extends ConsumerWidget {
  const SettingsCloudSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final connectivityAsync = ref.watch(connectivityStreamProvider);
    final syncAsync = ref.watch(syncStateStreamProvider);
    final user = ref.watch(currentUserProvider);
    final appMode = ref.watch(appModeProvider);
    final cloudAvailable = SupabaseConfig.isConfigured;
    final storedCredentials = ref.watch(cloudCredentialsProvider);
    final cloudSubtitle = _cloudSubtitle(
      l10n,
      configured: cloudAvailable,
      storedOnDevice: storedCredentials != null,
    );

    final isOnline =
        connectivityAsync.value ?? ConnectivityService.instance.isOnline;
    final syncState = syncAsync.value ?? SyncState.idle;
    final lastReport = ref.watch(syncLastReportProvider);

    return SettingsGroup(
      title: l10n.cloudSync,
      children: [
        ListTile(
          leading: Icon(
            !cloudAvailable
                ? Icons.cloud_off
                : appMode == AppMode.cloud
                ? Icons.cloud_done
                : Icons.phone_android,
          ),
          title: Text(
            !cloudAvailable
                ? l10n.cloudSyncUnavailable
                : appMode == AppMode.cloud
                ? l10n.cloudSyncOn(user?.email ?? '')
                : l10n.cloudSyncOff,
          ),
          subtitle: cloudSubtitle == null ? null : Text(cloudSubtitle),
          trailing: !cloudAvailable
              ? FilledButton.tonal(
                  onPressed: () => _configureCloud(context, ref, l10n),
                  child: Text(l10n.configure),
                )
              : appMode == AppMode.cloud
              ? TextButton(
                  onPressed: () => _confirmTurnOffCloud(context, ref, l10n),
                  child: Text(l10n.turnOff),
                )
              : FilledButton.tonal(
                  onPressed: () => _turnOnCloud(context, ref, l10n),
                  child: Text(l10n.turnOn),
                ),
        ),
        // One entry point at a time: while the tile above still offers
        // "Configure", this one would say the same thing twice. Once
        // there is a configuration, it becomes the way to edit or clear
        // it.
        if (cloudAvailable || storedCredentials != null)
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l10n.cloudConfiguration),
            subtitle: Text(l10n.cloudConfigIntro),
            trailing: const Icon(Icons.chevron_right),
            isThreeLine: true,
            onTap: () => _configureCloud(context, ref, l10n),
          ),
        if (appMode == AppMode.cloud) ...[
          ListTile(
            leading: Icon(
              isOnline ? Icons.cloud_done : Icons.cloud_off,
              color: isOnline ? context.medora.success : context.medora.warning,
            ),
            title: Text(isOnline ? l10n.online : l10n.offline),
            subtitle: Text(
              isOnline ? l10n.connectedSyncsAutomatically : l10n.usingLocalData,
            ),
            trailing: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? context.medora.success
                    : context.medora.warning,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              _syncIcon(syncState),
              color: _syncColor(context, syncState),
            ),
            title: Text(l10n.syncNow),
            subtitle: Text(_syncLabel(l10n, syncState)),
            trailing: syncState == SyncState.syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onTap: (syncState == SyncState.syncing || !isOnline)
                ? null
                : () => ref.read(syncServiceProvider).syncAll(),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.history),
            title: Text(_lastSyncText(l10n, lastReport)),
            // Rows inside their backoff window are skipped, not failed,
            // so they never reach the report's failure list — the tile
            // still has to open for them.
            trailing: _hasStuckRows(lastReport)
                ? const Icon(Icons.chevron_right)
                : null,
            onTap: _hasStuckRows(lastReport)
                ? () => showSyncFailures(ref, context, l10n, lastReport!)
                : null,
          ),
          // A project without the sync migration syncs nothing until the
          // file is applied; say which file, where the owner looks.
          if (lastReport?.missingMigration case final file?)
            ListTile(
              key: const Key('syncNeedsMigration'),
              dense: true,
              leading: Icon(Icons.error_outline, color: context.colors.error),
              title: Text(
                l10n.syncNeedsMigration(file),
                style: TextStyle(color: context.colors.error),
              ),
            ),
          ExpansionTile(
            title: Text(l10n.advanced),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (syncState == SyncState.syncing || !isOnline)
                          ? null
                          : () => showForceSyncDialog(context, ref, l10n, true),
                      icon: const Icon(Icons.upload_outlined, size: 18),
                      label: Text(l10n.forcePush),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.medora.warning,
                        side: BorderSide(color: context.medora.warning),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (syncState == SyncState.syncing || !isOnline)
                          ? null
                          : () =>
                                showForceSyncDialog(context, ref, l10n, false),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(l10n.forcePull),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// What the cloud tile says under its title: where the configuration came
/// from, or that a change only takes effect after a restart.
String? _cloudSubtitle(
  AppLocalizations l10n, {
  required bool configured,
  required bool storedOnDevice,
}) {
  if (SupabaseConfig.pendingRestart) return l10n.cloudRestartRequired;
  if (storedOnDevice) return l10n.cloudConfiguredOnDevice;
  if (configured) return l10n.cloudConfiguredFromBuild;
  return null;
}

/// Opens the configuration sheet and applies what the user decided there.
Future<void> _configureCloud(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await showCloudConfigSheet(context);
  switch (outcome) {
    case null:
      return;
    case CloudConfigOutcome.savedAndActive:
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudConfigSaved)));
    case CloudConfigOutcome.savedNeedsRestart:
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudRestartRequired)),
      );
    case CloudConfigOutcome.clearRequested:
      // Dropping the credentials while signed in would strand the account:
      // ask what happens to the local data first.
      if (ref.read(appModeProvider) == AppMode.cloud) {
        if (!context.mounted) return;
        final turnedOff = await _confirmTurnOffCloud(context, ref, l10n);
        if (!turnedOff) return;
      }
      await ref.read(cloudCredentialsProvider.notifier).clear();
      if (SupabaseConfig.isConfigured) SupabaseConfig.pendingRestart = true;
      messenger.showSnackBar(SnackBar(content: Text(l10n.cloudConfigCleared)));
  }
}

/// Returns true when cloud sync was actually turned off.
Future<bool> _confirmTurnOffCloud(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.turnOffCloudSync),
      content: Text(l10n.turnOffCloudSyncChoice),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'wipe'),
          child: Text(
            l10n.wipeLocalData,
            style: TextStyle(color: context.colors.error),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'keep'),
          child: Text(l10n.keepLocalData),
        ),
      ],
    ),
  );
  if (choice == null) return false;
  await ref.read(appModeProvider.notifier).set(AppMode.localOnly);
  await ref.read(authControllerProvider.notifier).signOut();
  if (choice == 'wipe') {
    try {
      ref.read(reminderSchedulerProvider).reset();
      await ref.read(localDataWiperProvider).wipe();
      ref.invalidate(medicationListProvider);
      ref.invalidate(treatmentListProvider);
      ref.invalidateDoseData();
      ref.invalidate(activePrescriptionsProvider);
      ref.invalidateRxData();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.wipeFailed(e.toString()))));
      }
    }
  }
  return true;
}

Future<void> _turnOnCloud(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
) async {
  try {
    await ref.read(appModeProvider.notifier).set(AppMode.cloud);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
    );
  }
}

IconData _syncIcon(SyncState state) {
  return switch (state) {
    SyncState.idle => Icons.sync,
    SyncState.syncing => Icons.sync,
    SyncState.success => Icons.check_circle,
    SyncState.partial => Icons.warning_amber_rounded,
    SyncState.error => Icons.error_outline,
  };
}

Color _syncColor(BuildContext context, SyncState state) {
  return switch (state) {
    SyncState.idle => context.colors.onSurfaceVariant,
    SyncState.syncing => context.colors.primary,
    SyncState.success => context.medora.success,
    SyncState.partial => context.medora.warning,
    SyncState.error => context.medora.danger,
  };
}

String _syncLabel(AppLocalizations l10n, SyncState state) {
  return switch (state) {
    SyncState.idle => l10n.syncIdle,
    SyncState.syncing => l10n.syncing,
    SyncState.success => l10n.syncSuccess,
    SyncState.partial => l10n.syncPartial,
    SyncState.error => l10n.syncError,
  };
}

String _lastSyncText(AppLocalizations l10n, SyncReport? r) {
  final finished = r?.finishedAt;
  if (r == null || finished == null) return l10n.syncNever;
  final summary = l10n.lastSyncSummary(
    finished.dateTimeFormatted,
    r.pushed,
    r.pulled,
    r.deleted,
    r.failures.length,
  );
  // Rows inside their retry backoff are not failures, so they only earn a
  // mention when there actually are some.
  if (r.skippedBackoff == 0) return summary;
  return '$summary · ${l10n.syncSkippedBackoff(r.skippedBackoff)}';
}

/// True when the last cycle left rows behind — failed outright, or skipped
/// because they are waiting out their retry backoff.
bool _hasStuckRows(SyncReport? r) =>
    r != null && (r.hasFailures || r.skippedBackoff > 0);
