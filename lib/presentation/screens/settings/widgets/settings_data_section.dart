/// Medora - Settings → Data: the registers, the export and the backups.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/settings/widgets/aifa_database_tile.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/presentation/screens/settings/widgets/supplement_register_tile.dart';
import 'package:medora/presentation/widgets/backup_photos_dialog.dart';
import 'package:medora/presentation/widgets/restore_dialog.dart';
import 'package:medora/services/backup_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The Data group: the two offline registers, the export screen, backup and
/// restore, and family sharing while cloud mode is on.
class SettingsDataSection extends ConsumerWidget {
  const SettingsDataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final caps = ref.watch(platformCapabilitiesProvider);
    final appMode = ref.watch(appModeProvider);
    return SettingsGroup(
      title: l10n.dataSection,
      children: [
        const AifaDatabaseTile(),
        if (caps.hasSupplementRegister) const SupplementRegisterTile(),
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
    );
  }
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

    if (!context.mounted) return;

    final isCloud = ref.read(appModeProvider) == AppMode.cloud;
    // Rewriting the whole database and re-reconciling the reminders takes
    // long enough on a full cabinet for the screen to look idle, and a
    // second tap on "Restore" while the first is running would read the
    // file twice. Block until it is done.
    final closeProgress = _showRestoreProgress(context, l10n);
    final BackupManifest applied;
    try {
      applied = await service.restore(file, mode: mode, markPending: isCloud);
      await _afterRestore(ref, isCloud: isCloud);
    } finally {
      closeProgress();
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.restoreDone(applied.totalRows))),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_backupError(l10n, e))));
  }
}

/// Puts up the un-dismissable "Restoring…" dialog; the returned callback
/// takes it down again, and is safe to call more than once.
///
/// Both halves name the **root** navigator. `showDialog` uses it by
/// default, while `Navigator.of(context)` inside the shell resolves to the
/// shell's navigator - taking the dialog down with that one would pop
/// `/settings` and leave the un-dismissable dialog on screen for good.
VoidCallback _showRestoreProgress(BuildContext context, AppLocalizations l10n) {
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 20),
              Expanded(child: Text(l10n.restoreInProgress)),
            ],
          ),
        ),
      ),
    ),
  );
  var closed = false;
  return () {
    if (closed) return;
    closed = true;
    navigator.pop();
  };
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
