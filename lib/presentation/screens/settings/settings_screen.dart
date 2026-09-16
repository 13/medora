/// Medora - Settings Screen
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_cloud_section.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_data_section.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_dialogs.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/presentation/widgets/update_tile.dart';

/// Asks the OS for permission to show notifications, and says so when it is
/// refused.
///
/// The switches call this before turning themselves on: a switch left on
/// after a denial promises reminders the system will never deliver, and
/// nothing else in the app would ever mention it.
Future<bool> _permitted(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
) async {
  final granted = await ref.read(reminderPortProvider).ensurePermissions();
  if (!granted && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.notificationsBlocked)));
  }
  return granted;
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final biometricsEnabled = ref.watch(biometricsEnabledProvider);
    final remindersEnabled = ref.watch(remindersEnabledProvider);
    final graceMinutes = ref.watch(missedGraceMinutesProvider);
    final buildInfoAsync = ref.watch(buildInfoProvider);
    final caps = ref.watch(platformCapabilitiesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          // ── Appearance ─────────────────────────────────────
          SettingsGroup(
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
                onTap: () => showLanguagePicker(context, ref, l10n, locale),
              ),

              // Color Scheme
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: Text(l10n.colorScheme),
                subtitle: Text(l10n.colorSchemeDesc),
                trailing: ColorDot(ref.watch(colorSchemeProvider).color),
                onTap: () => showColorSchemePicker(context, ref, l10n),
              ),
            ],
          ),

          // ── Notifications ──────────────────────────────────
          // Gated as a whole: the reminder service early-returns from every
          // method where the platform cannot schedule, so on desktop and web
          // every tile here would claim to do something it cannot.
          if (caps.hasLocalNotifications)
            SettingsGroup(
              title: l10n.notifications,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: Text(l10n.enableNotifications),
                  subtitle: Text(l10n.receiveDoseReminders),
                  value: remindersEnabled,
                  onChanged: (value) async {
                    if (value && !await _permitted(context, ref, l10n)) return;
                    await ref
                        .read(remindersEnabledProvider.notifier)
                        .set(value);
                    // Both schedulers: this is the master switch, so the
                    // stock and expiry alerts go off with it — and have to
                    // come back when it goes on again.
                    if (value) {
                      ref.read(reminderSchedulerProvider).reset();
                      ref.read(stockReminderSchedulerProvider).reset();
                    }
                    await ref.read(reminderSchedulerProvider).reconcile();
                    await ref.read(stockReminderSchedulerProvider).reconcile();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.inventory_2_outlined),
                  title: Text(l10n.stockAndExpiryReminders),
                  subtitle: Text(l10n.stockAndExpiryRemindersHint),
                  // Nested under the master switch, like the cancel tile
                  // below: with notifications off nothing here is scheduled,
                  // so the switch must not claim otherwise.
                  value:
                      remindersEnabled &&
                      ref.watch(stockRemindersEnabledProvider),
                  onChanged: remindersEnabled
                      ? (value) async {
                          if (value && !await _permitted(context, ref, l10n)) {
                            return;
                          }
                          await ref
                              .read(stockRemindersEnabledProvider.notifier)
                              .set(value);
                          unawaited(
                            ref
                                .read(stockReminderSchedulerProvider)
                                .reconcile(),
                          );
                        }
                      : null,
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
                      // cancelAll() takes every kind of notification with
                      // it, so both schedulers have to forget their
                      // snapshots — otherwise the stock and expiry alerts
                      // are gone from the OS while the snapshot still says
                      // they are booked, and nothing ever re-books them.
                      ref.read(reminderSchedulerProvider).reset();
                      ref.read(stockReminderSchedulerProvider).reset();
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
                      await ref
                          .read(missedGraceMinutesProvider.notifier)
                          .set(v);
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
            SettingsGroup(
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
          const SettingsDataSection(),

          // ── Cloud sync ─────────────────────────────────────
          const SettingsCloudSection(),

          // ── Danger Zone ────────────────────────────────────
          SettingsGroup(
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
                onTap: () => showDeleteAllDialog(context, ref, l10n),
              ),
            ],
          ),

          // ── About ──────────────────────────────────────────
          SettingsGroup(
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
}
