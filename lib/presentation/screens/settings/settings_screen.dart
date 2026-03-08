/// Medora - Settings Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/sync_service.dart';
import 'package:medora/services/aifa_cache_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final connectivityAsync = ref.watch(connectivityStreamProvider);
    final syncAsync = ref.watch(syncStateStreamProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

    final isOnline = connectivityAsync.value ?? ConnectivityService.instance.isOnline;
    final syncState = syncAsync.value ?? SyncState.idle;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          // ── Appearance ─────────────────────────────────────
          _SectionTitle(l10n.appearance),

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
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: const Icon(Icons.brightness_auto, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: const Icon(Icons.light_mode, size: 18),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: const Icon(Icons.dark_mode, size: 18),
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
          const Divider(),

          // ── AIFA Database ──────────────────────────────────
          _SectionTitle(l10n.aifaDatabase),
          _AifaDatabaseTile(),
          const Divider(),

          // ── Notifications ──────────────────────────────────
          _SectionTitle(l10n.notifications),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Text(l10n.enableNotifications),
            subtitle: Text(l10n.receiveDoseReminders),
            trailing: Switch(
              value: true,
              onChanged: (value) async {
                if (value) {
                  await ReminderService.instance.requestPermissions();
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cancel_outlined),
            title: Text(l10n.cancelAllReminders),
            subtitle: Text(l10n.removePendingNotifications),
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
                await ReminderService.instance.cancelAllReminders();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.allRemindersCancelled)),
                  );
                }
              }
            },
          ),
          const Divider(),

          // ── Data & Sync ────────────────────────────────────
          _SectionTitle(l10n.dataAndSync),
          ListTile(
            leading: Icon(
              isOnline ? Icons.cloud_done : Icons.cloud_off,
              color: isOnline ? AppTheme.successColor : Colors.orange,
            ),
            title: Text(isOnline ? l10n.online : l10n.offline),
            subtitle: Text(isOnline
                ? l10n.connectedSyncsAutomatically
                : l10n.usingLocalData),
            trailing: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline ? AppTheme.successColor : Colors.orange,
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              _syncIcon(syncState),
              color: _syncColor(syncState),
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
            onTap: syncState == SyncState.syncing
                ? null
                : () => ref.read(syncServiceProvider).syncAll(),
          ),
          const Divider(),

          // ── Features ───────────────────────────────────────
          _SectionTitle(l10n.features),
          ListTile(
            leading: const Icon(Icons.people),
            title: Text(l10n.familySharing),
            subtitle: Text(l10n.shareCabinetWithFamily),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.family),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.exportData),
            subtitle: Text(l10n.exportAsCsvOrPdf),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.export),
          ),
          const Divider(),

          // ── Danger Zone ────────────────────────────────────
          _SectionTitle(l10n.dangerZone),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l10n.deleteAllData,
                style: const TextStyle(color: Colors.red)),
            subtitle: Text(l10n.deleteAllDataDesc),
            onTap: () => _showDeleteAllDialog(context, ref, l10n),
          ),
          const Divider(),

          // ── About ──────────────────────────────────────────
          _SectionTitle(l10n.about),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.appVersion),
            subtitle: const Text(AppConstants.appVersion),
          ),
          const SizedBox(height: 32),
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
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.red),
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
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: controller.text == 'DELETE'
                  ? () async {
                      Navigator.pop(ctx);
                      // Delete local data
                      await AppDatabase.instance.clearAllData();
                      // Try to delete remote data
                      // With RLS enabled, this only deletes the current user's data
                      if (SupabaseConfig.isAuthenticated) {
                        try {
                          final client = SupabaseConfig.client;
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
                        } catch (_) {
                          // Ignore remote errors — local is already cleared
                        }
                      }
                      // Invalidate all providers
                      ref.invalidate(medicationListProvider);
                      ref.invalidate(treatmentListProvider);
                      ref.invalidate(todaysDoseLogsProvider);
                      ref.invalidate(activePrescriptionsProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.allDataDeleted)),
                        );
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
      _LanguageOption(null, l10n.systemDefault, '🌐'),
      _LanguageOption(const Locale('en'), 'English', '🇬🇧'),
      _LanguageOption(const Locale('de'), 'Deutsch', '🇩🇪'),
      _LanguageOption(const Locale('it'), 'Italiano', '🇮🇹'),
    ];

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.language,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ...options.map((opt) {
              final isSelected = current?.languageCode == opt.locale?.languageCode &&
                  (opt.locale != null || current == null);
              return ListTile(
                leading: Text(opt.flag, style: const TextStyle(fontSize: 24)),
                title: Text(opt.label),
                trailing:
                    isSelected ? const Icon(Icons.check, color: AppTheme.primaryColor) : null,
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
      SyncState.error => Icons.error_outline,
    };
  }

  Color _syncColor(SyncState state) {
    return switch (state) {
      SyncState.idle => Colors.grey,
      SyncState.syncing => AppTheme.primaryColor,
      SyncState.success => AppTheme.successColor,
      SyncState.error => Colors.red,
    };
  }

  String _syncLabel(AppLocalizations l10n, SyncState state) {
    return switch (state) {
      SyncState.idle => l10n.syncIdle,
      SyncState.syncing => l10n.syncing,
      SyncState.success => l10n.syncSuccess,
      SyncState.error => l10n.syncError,
    };
  }

  void _showColorSchemePicker(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final current = ref.read(colorSchemeProvider);
    final schemes = AppColorScheme.values;

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

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.colorScheme,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                    width: 3)
                                : null,
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color:
                                          scheme.color.withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      spreadRadius: 2,
                                    )
                                  ]
                                : null,
                          ),
                          child: isSelected
                              ? const Icon(Icons.check,
                                  color: Colors.white, size: 22)
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
        border: Border.all(
          color: Theme.of(context).dividerColor,
          width: 1,
        ),
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
          _lastSync = DateTime.now();
          _count = count;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.aifaSyncSuccess(count))),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _statusMessage = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.aifaSyncError)),
        );
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
  const _LanguageOption(this.locale, this.label, this.flag);
  final Locale? locale;
  final String label;
  final String flag;
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
