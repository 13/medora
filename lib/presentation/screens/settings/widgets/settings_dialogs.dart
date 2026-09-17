/// Medora - Settings: the dialogs and pickers the screen opens.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';

void showForceSyncDialog(
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

void showDeleteAllDialog(
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
                      // The server first: it also tells the other devices.
                      final remote = ref.read(accountDataDatasourceProvider);
                      if (remote != null && SupabaseConfig.isAuthenticated) {
                        await remote.deleteAllData();
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
                            content: Text(l10n.deleteDataFailed(e.toString())),
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

void showLanguagePicker(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations l10n,
  Locale? current,
) {
  final options = <LanguageOption>[
    LanguageOption(null, l10n.systemDefault),
    const LanguageOption(Locale('en'), 'English'),
    const LanguageOption(Locale('de'), 'Deutsch'),
    const LanguageOption(Locale('it'), 'Italiano'),
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

Future<void> showSyncFailures(
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.ok)),
        ],
      ),
    ),
  );
}

void showColorSchemePicker(
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
                                    color: scheme.color.withValues(alpha: 0.4),
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
