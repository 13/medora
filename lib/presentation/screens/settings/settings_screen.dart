/// Medora - Settings Screen
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/backup_photos_dialog.dart';
import 'package:medora/presentation/widgets/cloud_config_sheet.dart';
import 'package:medora/presentation/widgets/restore_dialog.dart';
import 'package:medora/presentation/widgets/update_tile.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/backup_service.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final connectivityAsync = ref.watch(connectivityStreamProvider);
    final syncAsync = ref.watch(syncStateStreamProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final user = ref.watch(currentUserProvider);
    final appMode = ref.watch(appModeProvider);
    final cloudAvailable = SupabaseConfig.isConfigured;
    final storedCredentials = ref.watch(cloudCredentialsProvider);
    final cloudSubtitle = _cloudSubtitle(
      l10n,
      configured: cloudAvailable,
      storedOnDevice: storedCredentials != null,
    );
    final biometricsEnabled = ref.watch(biometricsEnabledProvider);
    final remindersEnabled = ref.watch(remindersEnabledProvider);
    final graceMinutes = ref.watch(missedGraceMinutesProvider);
    final buildInfoAsync = ref.watch(buildInfoProvider);
    final caps = ref.watch(platformCapabilitiesProvider);

    final isOnline =
        connectivityAsync.value ?? ConnectivityService.instance.isOnline;
    final syncState = syncAsync.value ?? SyncState.idle;
    final lastReport = ref.watch(syncLastReportProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          // ── Appearance ─────────────────────────────────────
          _SettingsGroup(
            title: l10n.appearance,
            children: [
              // Dark mode
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: Text(l10n.darkMode),
                subtitle: Text(_themeLabel(l10n, themeMode)),
                trailing: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    const ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto, size: 18),
                    ),
                    const ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode, size: 18),
                    ),
                    const ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode, size: 18),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (v) =>
                      ref.read(themeModeProvider.notifier).set(v.first),
                ),
              ),

              // Language
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(l10n.language),
                subtitle: Text(_localeLabel(l10n, locale)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showLanguagePicker(context, ref, l10n, locale),
              ),

              // Color Scheme
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: Text(l10n.colorScheme),
                subtitle: Text(l10n.colorSchemeDesc),
                trailing: _ColorDot(ref.watch(colorSchemeProvider).color),
                onTap: () => _showColorSchemePicker(context, ref, l10n),
              ),
            ],
          ),

          // ── Notifications ──────────────────────────────────
          _SettingsGroup(
            title: l10n.notifications,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_outlined),
                title: Text(l10n.enableNotifications),
                subtitle: Text(l10n.receiveDoseReminders),
                value: remindersEnabled,
                onChanged: (value) async {
                  if (value) {
                    await ReminderService.instance.requestPermissions();
                  }
                  await ref.read(remindersEnabledProvider.notifier).set(value);
                  if (value) ref.read(reminderSchedulerProvider).reset();
                  await ref.read(reminderSchedulerProvider).reconcile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: Text(l10n.cancelAllReminders),
                subtitle: Text(l10n.removePendingNotifications),
                enabled: remindersEnabled,
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(l10n.cancelAllReminders),
                      content: Text(l10n.cancelAllRemindersConfirm),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(l10n.no),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(l10n.yes),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && context.mounted) {
                    await ref.read(reminderPortProvider).cancelAll();
                    ref.read(reminderSchedulerProvider).reset();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.allRemindersCancelled)),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: Text(l10n.missedGracePeriod),
                subtitle: Text(l10n.missedGracePeriodDesc),
                trailing: DropdownButton<int>(
                  value: kMissedGraceOptions.contains(graceMinutes)
                      ? graceMinutes
                      : 120,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final m in kMissedGraceOptions)
                      DropdownMenuItem(
                        value: m,
                        child: Text(
                          m < 60
                              ? l10n.minutesShort(m)
                              : l10n.hoursShort(m ~/ 60),
                        ),
                      ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await ref.read(missedGraceMinutesProvider.notifier).set(v);
                    await ref
                        .read(appStartupTasksProvider)
                        .run(includeSync: false);
                  },
                ),
              ),
            ],
          ),

          // ── Security ───────────────────────────────────────
          if (caps.hasBiometrics)
            _SettingsGroup(
              title: l10n.securitySection,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint),
                  title: Text(l10n.fingerprintUnlock),
                  subtitle: Text(l10n.fingerprintUnlockDesc),
                  value: biometricsEnabled,
                  onChanged: (value) =>
                      ref.read(biometricsEnabledProvider.notifier).set(value),
                ),
              ],
            ),

          // ── Data ───────────────────────────────────────────
          _SettingsGroup(
            title: l10n.dataSection,
            children: [
              _AifaDatabaseTile(),
              if (caps.hasFileShare)
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l10n.exportData),
                  subtitle: Text(l10n.exportAsCsvOrPdf),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(AppRoutes.export),
                ),
              if (caps.hasFileShare) ...[
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: Text(l10n.backupData),
                  subtitle: Text(l10n.backupDataHint),
                  trailing: const Icon(Icons.ios_share),
                  onTap: () => _backupData(context, ref, l10n),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: Text(l10n.restoreBackup),
                  subtitle: Text(l10n.restoreBackupHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _restoreBackup(context, ref, l10n),
                ),
              ],
              if (appMode == AppMode.cloud)
                ListTile(
                  leading: const Icon(Icons.people),
                  title: Text(l10n.familySharing),
                  subtitle: Text(l10n.shareCabinetWithFamily),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(AppRoutes.family),
                ),
            ],
          ),

          // ── Cloud sync ─────────────────────────────────────
          _SettingsGroup(
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
                        onPressed: () =>
                            _confirmTurnOffCloud(context, ref, l10n),
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
                    color: isOnline
                        ? context.medora.success
                        : context.medora.warning,
                  ),
                  title: Text(isOnline ? l10n.online : l10n.offline),
                  subtitle: Text(
                    isOnline
                        ? l10n.connectedSyncsAutomatically
                        : l10n.usingLocalData,
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
                      ? () => _showSyncFailures(ref, context, l10n, lastReport!)
                      : null,
                ),
                ExpansionTile(
                  title: Text(l10n.advanced),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                (syncState == SyncState.syncing || !isOnline)
                                ? null
                                : () => _showForceSyncDialog(
                                    context,
                                    ref,
                                    l10n,
                                    true,
                                  ),
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
                            onPressed:
                                (syncState == SyncState.syncing || !isOnline)
                                ? null
                                : () => _showForceSyncDialog(
                                    context,
                                    ref,
                                    l10n,
                                    false,
                                  ),
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
          ),

          // ── Danger Zone ────────────────────────────────────
          _SettingsGroup(
            title: l10n.dangerZone,
            children: [
              ListTile(
                leading: Icon(
                  Icons.delete_forever,
                  color: context.colors.error,
                ),
                title: Text(
                  l10n.deleteAllData,
                  style: TextStyle(color: context.colors.error),
                ),
                subtitle: Text(l10n.deleteAllDataDesc),
                onTap: () => _showDeleteAllDialog(context, ref, l10n),
              ),
            ],
          ),

          // ── About ──────────────────────────────────────────
          _SettingsGroup(
            title: l10n.about,
            children: [
              ...buildInfoAsync.maybeWhen(
                data: (info) => _aboutRows(context, l10n, info),
                orElse: () => [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l10n.appVersion),
                    subtitle: const Text('…'),
                  ),
                ],
              ),
              // Renders nothing where in-app updates are unavailable.
              const UpdateTile(),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
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
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.cloudConfigCleared)),
        );
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
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.wipeFailed(e.toString()))),
          );
        }
      }
    }
    return true;
  }

  /// Writes a full backup into the cache and hands it to the share sheet.
  ///
  /// The photos are the only part that can make the file unwieldy, so when
  /// there are any the user is asked first (see [BackupPhotosDialog]). The
  /// file lives in the cache just long enough for the share sheet to copy it:
  /// it is unencrypted, so it is deleted again on the way out.
  Future<void> _backupData(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(backupServiceProvider);
    File? file;
    try {
      var includePhotos = true;
      final photoCount = await service.countPhotos();
      if (photoCount > 0) {
        final photoBytes = await service.estimatePhotoBytes();
        if (!context.mounted) return;
        final choice = await showBackupPhotosDialog(
          context,
          photoCount: photoCount,
          photoBytes: photoBytes,
        );
        if (choice == null) return;
        includePhotos = choice;
      }

      final dir = await getTemporaryDirectory();
      file = await service.exportToFile(dir, includePhotos: includePhotos);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_backupError(l10n, e))));
    } finally {
      try {
        await file?.delete();
      } on FileSystemException {
        // Already gone, or the platform holds it: nothing worth reporting.
      }
    }
  }

  /// Picks a backup file, confirms what it holds, then applies it.
  Future<void> _restoreBackup(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(backupServiceProvider);
    try {
      final file = await ref.read(backupFilePickerProvider)();
      if (file == null) return;
      final manifest = await service.inspect(file);
      if (!context.mounted) return;
      final mode = await showRestoreDialog(context, manifest);
      if (mode == null) return;

      final isCloud = ref.read(appModeProvider) == AppMode.cloud;
      final applied = await service.restore(
        file,
        mode: mode,
        markPending: isCloud,
      );
      await _afterRestore(ref, isCloud: isCloud);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.restoreDone(applied.totalRows))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_backupError(l10n, e))));
    }
  }

  /// Every cached view of the database is stale after a restore.
  Future<void> _afterRestore(WidgetRef ref, {required bool isCloud}) async {
    ref.read(reminderSchedulerProvider).reset();
    await ref.read(reminderSchedulerProvider).reconcile();
    await ref.read(medicationListProvider.notifier).refresh();
    await ref.read(treatmentListProvider.notifier).refresh();
    ref.invalidateDoseData();
    ref.invalidate(activePrescriptionsProvider);
    if (!isCloud) return;
    // Restored rows are already pending_update; this also clears the pull
    // cursors so the next cycle re-reads everything the account holds.
    final userId = ref.read(currentUserProvider)?.id;
    if (userId != null) {
      await ref.read(localUploadMarkerProvider).markAllForUpload(userId);
    }
  }

  String _backupError(AppLocalizations l10n, Object error) {
    if (error is! BackupException) return l10n.errorWithDetails('$error');
    return switch (error.kind) {
      BackupErrorKind.notABackup => l10n.backupNotABackup,
      BackupErrorKind.newerFormat ||
      BackupErrorKind.newerSchema => l10n.backupNewerVersion,
      BackupErrorKind.corrupt => l10n.backupCorrupt,
      BackupErrorKind.io => l10n.errorWithDetails('${error.details}'),
    };
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

  void _showForceSyncDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    bool isPush,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isPush ? l10n.forcePushTitle : l10n.forcePullTitle),
        content: Text(isPush ? l10n.forcePushConfirm : l10n.forcePullConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (isPush) {
                ref.read(syncServiceProvider).forcePush();
              } else {
                ref.read(syncServiceProvider).forcePull();
              }
            },
            child: Text(
              l10n.continueAction,
              style: TextStyle(
                color: isPush ? context.medora.warning : context.colors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteAllDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: context.colors.error),
              const SizedBox(width: 8),
              Text(l10n.deleteAllData),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.deleteAllDataConfirm),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: l10n.typeDeleteToConfirm,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: context.colors.error,
                foregroundColor: context.colors.onError,
              ),
              onPressed: controller.text == 'DELETE'
                  ? () async {
                      Navigator.pop(ctx);
                      try {
                        // Try to delete remote data first
                        final client = SupabaseConfig.clientOrNull;
                        if (client != null && SupabaseConfig.isAuthenticated) {
                          // Delete in FK order: dose_logs → prescriptions → treatments → medications
                          await client
                              .from(AppConstants.doseLogsTable)
                              .delete()
                              .neq('id', '');
                          await client
                              .from(AppConstants.prescriptionsTable)
                              .delete()
                              .neq('id', '');
                          await client
                              .from(AppConstants.treatmentsTable)
                              .delete()
                              .neq('id', '');
                          await client
                              .from(AppConstants.medicationsTable)
                              .delete()
                              .neq('id', '');
                        }
                        // If remote deletion is successful, delete local data
                        ref.read(reminderSchedulerProvider).reset();
                        await ref.read(localDataWiperProvider).wipe();

                        // Invalidate all providers
                        ref.invalidate(medicationListProvider);
                        ref.invalidate(treatmentListProvider);
                        ref.invalidateDoseData();
                        ref.invalidate(activePrescriptionsProvider);

                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.allDataDeleted)),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.deleteDataFailed(e.toString()),
                              ),
                            ),
                          );
                        }
                      }
                    }
                  : null,
              child: Text(l10n.delete),
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguagePicker(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Locale? current,
  ) {
    final options = <_LanguageOption>[
      _LanguageOption(null, l10n.systemDefault),
      const _LanguageOption(Locale('en'), 'English'),
      const _LanguageOption(Locale('de'), 'Deutsch'),
      const _LanguageOption(Locale('it'), 'Italiano'),
    ];

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.language,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ...options.map((opt) {
              final isSelected =
                  current?.languageCode == opt.locale?.languageCode &&
                  (opt.locale != null || current == null);
              return ListTile(
                title: Text(opt.label),
                trailing: isSelected
                    ? Icon(Icons.check, color: context.colors.primary)
                    : null,
                onTap: () {
                  ref.read(localeProvider.notifier).set(opt.locale);
                  Navigator.pop(ctx);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _themeLabel(AppLocalizations l10n, ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => l10n.systemDefault,
      ThemeMode.light => l10n.lightMode,
      ThemeMode.dark => l10n.darkModeLabel,
    };
  }

  String _localeLabel(AppLocalizations l10n, Locale? locale) {
    if (locale == null) return l10n.systemDefault;
    return switch (locale.languageCode) {
      'en' => 'English',
      'de' => 'Deutsch',
      'it' => 'Italiano',
      _ => locale.languageCode,
    };
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

  /// The About group's rows: version, build number, build date, commit and
  /// channel — each long-pressable to copy a one-line summary, plus a Dart
  /// runtime row.
  List<Widget> _aboutRows(
    BuildContext context,
    AppLocalizations l10n,
    BuildInfo info,
  ) {
    final dateText = _formatBuildDate(info.buildDate);
    final shaText = info.gitSha.isEmpty ? '—' : info.gitSha;
    final channelText = _channelLabel(l10n, info.channel);

    void copySummary() {
      final summary =
          'Medora ${info.version} (${info.buildNumber}) · '
          '$dateText · $shaText · $channelText';
      Clipboard.setData(ClipboardData(text: summary));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.copiedToClipboard)));
    }

    return [
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(l10n.appVersion),
        subtitle: Text(info.version),
        onLongPress: copySummary,
      ),
      ListTile(
        leading: const Icon(Icons.tag_outlined),
        title: Text(l10n.buildNumber),
        subtitle: Text(info.buildNumber),
        onLongPress: copySummary,
      ),
      ListTile(
        leading: const Icon(Icons.event_outlined),
        title: Text(l10n.buildDate),
        subtitle: Text(dateText),
        onLongPress: copySummary,
      ),
      ListTile(
        leading: const Icon(Icons.commit_outlined),
        title: Text(l10n.buildCommit),
        subtitle: Text(shaText),
        onLongPress: copySummary,
      ),
      ListTile(
        leading: const Icon(Icons.flag_outlined),
        title: Text(l10n.buildChannel),
        subtitle: Text(channelText),
        onLongPress: copySummary,
      ),
      ListTile(
        leading: const Icon(Icons.code),
        title: const Text('Dart'), // l10n-exempt: proper noun
        subtitle: Text(info.dartVersion),
        onLongPress: copySummary,
      ),
    ];
  }

  /// Parses the ISO-8601 UTC [iso] build date and renders it with the
  /// locale-aware extension; `''` (a local/dev build) becomes '—'.
  String _formatBuildDate(String iso) {
    if (iso.isEmpty) return '—';
    final date = DateTime.tryParse(iso);
    if (date == null) return '—';
    return '${date.toUtc().dateTimeFormatted} UTC';
  }

  String _channelLabel(AppLocalizations l10n, String channel) =>
      switch (channel) {
        'release' => l10n.channelRelease,
        'ci' => l10n.channelCi,
        _ => l10n.channelDev,
      };

  /// True when the last cycle left rows behind — failed outright, or skipped
  /// because they are waiting out their retry backoff.
  static bool _hasStuckRows(SyncReport? r) =>
      r != null && (r.hasFailures || r.skippedBackoff > 0);

  Future<void> _showSyncFailures(
    WidgetRef ref,
    BuildContext context,
    AppLocalizations l10n,
    SyncReport r,
  ) async {
    // The report only knows about rows that were tried this cycle; the store
    // also holds the ones skipped inside their backoff window.
    var stored = const <SyncFailedRow>[];
    try {
      stored = await ref.read(syncFailureStoreProvider).listAll();
    } catch (e) {
      debugPrint('Settings: could not read the failure store: $e');
    }
    if (!context.mounted) return;

    final rows = <({String table, String id, String? detail})>[
      for (final f in r.failures) (table: f.table, id: f.id, detail: f.error),
    ];
    final seen = {for (final row in rows) '${row.table}/${row.id}'};
    for (final s in stored) {
      if (seen.add('${s.table}/${s.id}')) {
        rows.add((table: s.table, id: s.id, detail: null));
      }
    }

    // Rows the user gives up on, so the dialog can drop them without waiting
    // for another cycle to rebuild the report.
    final discarded = <String>{};
    // The row whose discard is in flight: its button (and every other one)
    // stays disabled until the server has answered.
    String? busy;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l10n.syncFailedItems),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.discardLocalChangeHint,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
                for (final f in rows)
                  if (!discarded.contains('${f.table}/${f.id}'))
                    ListTile(
                      dense: true,
                      title: Text('${f.table} · ${f.id}'),
                      subtitle: f.detail == null ? null : Text(f.detail!),
                      trailing: TextButton(
                        onPressed: busy != null
                            ? null
                            : () async {
                                final key = '${f.table}/${f.id}';
                                setState(() => busy = key);
                                try {
                                  await ref
                                      .read(syncServiceProvider)
                                      .discardFailedRow(f.table, f.id);
                                  if (!ctx.mounted) return;
                                  setState(() {
                                    discarded.add(key);
                                    busy = null;
                                  });
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  setState(() => busy = null);
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.errorWithDetails(e.toString()),
                                      ),
                                    ),
                                  );
                                }
                              },
                        child: Text(l10n.discardLocalChange),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ok),
            ),
          ],
        ),
      ),
    );
  }

  void _showColorSchemePicker(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final current = ref.read(colorSchemeProvider);
    const schemes = AppColorScheme.values;

    String colorLabel(AppColorScheme scheme) {
      return switch (scheme) {
        AppColorScheme.teal => l10n.colorTeal,
        AppColorScheme.blue => l10n.colorBlue,
        AppColorScheme.indigo => l10n.colorIndigo,
        AppColorScheme.purple => l10n.colorPurple,
        AppColorScheme.pink => l10n.colorPink,
        AppColorScheme.red => l10n.colorRed,
        AppColorScheme.orange => l10n.colorOrange,
        AppColorScheme.green => l10n.colorGreen,
      };
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.colorScheme,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: schemes.map((scheme) {
                  final isSelected = scheme == current;
                  return GestureDetector(
                    onTap: () {
                      ref.read(colorSchemeProvider.notifier).set(scheme);
                      Navigator.pop(ctx);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: scheme.color,
                            shape: BoxShape.circle,
                            border: isSelected
                                ? Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    width: 3,
                                  )
                                : null,
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: scheme.color.withValues(
                                        alpha: 0.4,
                                      ),
                                      blurRadius: 8,
                                      spreadRadius: 2,
                                    ),
                                  ]
                                : null,
                          ),
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  // on user-chosen swatch
                                  color:
                                      ThemeData.estimateBrightnessForColor(
                                            scheme.color,
                                          ) ==
                                          Brightness.dark
                                      ? const Color(0xFFFFFFFF)
                                      : const Color(0xFF000000),
                                  size: 22,
                                )
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          colorLabel(scheme),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────

class _ColorDot extends StatelessWidget {
  const _ColorDot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
    );
  }
}

class _AifaDatabaseTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AifaDatabaseTile> createState() => _AifaDatabaseTileState();
}

class _AifaDatabaseTileState extends ConsumerState<_AifaDatabaseTile> {
  bool _isSyncing = false;
  String? _statusMessage;
  DateTime? _lastSync;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final lastSync = await AifaCacheService.instance.getLastSyncDate();
    final count = await AifaCacheService.instance.getCachedCount();
    if (mounted) {
      setState(() {
        _lastSync = lastSync;
        _count = count;
      });
    }
  }

  Future<void> _syncDatabase() async {
    if (_isSyncing) return;
    final l10n = AppLocalizations.of(context);

    setState(() {
      _isSyncing = true;
      _statusMessage = l10n.aifaSyncing;
    });

    try {
      final count = await AifaCacheService.instance.syncDatabase(
        onProgress: (status) {
          if (mounted) setState(() => _statusMessage = status);
        },
      );

      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = null;
          _lastSync = ref.read(nowProvider)();
          _count = count;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.aifaSyncSuccess(count))));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.aifaSyncError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final status = _isSyncing
        ? _statusMessage ?? l10n.aifaSyncing
        : _lastSync != null
        ? '${l10n.aifaLastSync(_lastSync!.formatted)} · $_count'
        : l10n.aifaNeverSynced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text(l10n.aifaDatabase),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(l10n.aifaDatabaseHint), Text(status)],
          ),
          isThreeLine: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton.icon(
                    onPressed: _syncDatabase,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(l10n.syncAifaDatabase),
                  ),
          ),
        ),
      ],
    );
  }
}

class _LanguageOption {
  const _LanguageOption(this.locale, this.label);
  final Locale? locale;
  final String label;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _SectionTitle(title),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: children),
      ),
    ],
  );
}
