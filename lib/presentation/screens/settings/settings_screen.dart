/// Medora - Settings Screen
library;

import 'package:flutter/material.dart';
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
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/sync_service.dart';

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
    final biometricsEnabled = ref.watch(biometricsEnabledProvider);
    final remindersEnabled = ref.watch(remindersEnabledProvider);
    final graceMinutes = ref.watch(missedGraceMinutesProvider);
    final appVersionAsync = ref.watch(appVersionProvider);
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
                trailing: !cloudAvailable
                    ? null
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
                  trailing: (lastReport?.hasFailures ?? false)
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap: (lastReport?.hasFailures ?? false)
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
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.appVersion),
                subtitle: Text(
                  appVersionAsync.maybeWhen(data: (v) => v, orElse: () => '…'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _confirmTurnOffCloud(
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
    if (choice == null) return;
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

  void _showSyncFailures(
    WidgetRef ref,
    BuildContext context,
    AppLocalizations l10n,
    SyncReport r,
  ) {
    // Rows the user gives up on, so the dialog can drop them without waiting
    // for another cycle to rebuild the report.
    final discarded = <String>{};
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l10n.syncFailedItems),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final f in r.failures)
                  if (!discarded.contains('${f.table}/${f.id}'))
                    ListTile(
                      dense: true,
                      title: Text('${f.table} · ${f.id}'),
                      subtitle: Text(f.error),
                      trailing: TextButton(
                        onPressed: () async {
                          await ref
                              .read(syncServiceProvider)
                              .discardFailedRow(f.table, f.id);
                          setState(() => discarded.add('${f.table}/${f.id}'));
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

    final subtitle = _isSyncing
        ? _statusMessage ?? l10n.aifaSyncing
        : _lastSync != null
        ? '${l10n.aifaLastSync(_formatDate(_lastSync!))} · $_count'
        : l10n.aifaNeverSynced;

    return ListTile(
      leading: const Icon(Icons.storage_outlined),
      title: Text(l10n.aifaDatabaseDesc),
      subtitle: Text(subtitle),
      trailing: _isSyncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _syncDatabase,
              child: Text(l10n.syncAifaDatabase),
            ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}.'
        '${date.year}';
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
