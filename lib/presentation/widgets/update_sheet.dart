/// Medora - The update details sheet.
///
/// Opened from the Settings tile and the Home banner. It is the only place
/// that starts a download, so the buttons follow the state machine directly:
/// Download -> progress -> Install, with "Later" dismissing the release.
/// A download in flight offers Cancel, and Install stops once more to explain
/// what Android is about to ask for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:medora/services/release_notes.dart';

/// Opens [UpdateSheet] as a modal bottom sheet.
Future<void> showUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const UpdateSheet(),
  );
}

/// The message for an [UpdateException] - the kinds the user can act on get
/// their own wording, everything else is a generic failure.
String updateErrorMessage(AppLocalizations l10n, UpdateException error) =>
    switch (error.kind) {
      UpdateErrorKind.checksum => l10n.updateChecksumFailed,
      UpdateErrorKind.noAsset => l10n.updateNoAsset,
      _ => l10n.updateFailed,
    };

/// Explains what the system is about to ask, before the installer opens.
///
/// Sideloading an APK is a permission prompt the user has most likely never
/// seen, and one that looks alarming out of context; saying up front who asks
/// for what (and that nothing leaves the device) is the difference between a
/// deliberate install and an abandoned one.
Future<bool> confirmInstall(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.updateInstallExplainTitle),
      content: Text(l10n.updateInstallExplainBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.continueAction),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class UpdateSheet extends ConsumerWidget {
  const UpdateSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(appUpdateProvider).value ?? const UpdateUnknown();
    final release = switch (status) {
      UpdateAvailable(:final release) => release,
      UpdateDownloading(:final release) => release,
      UpdateReady(:final release) => release,
      _ => null,
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (release != null) ...[
              Text(release.title, style: context.text.titleLarge),
              const SizedBox(height: 4),
              Text(
                release.version.label,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              if (release.publishedAt case final publishedAt?) ...[
                const SizedBox(height: 2),
                Text(
                  l10n.updatePublished(publishedAt.formatted),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
              _WhatsNew(notes: release.notes),
            ],
            if (status is UpdateFailed) ...[
              const SizedBox(height: 16),
              Text(
                updateErrorMessage(l10n, status.error),
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.error,
                ),
              ),
            ],
            if (status is UpdateDownloading) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(value: status.progress),
            ],
            const SizedBox(height: 24),
            _Actions(status: status),
          ],
        ),
      ),
    );
  }
}

/// The release body, made readable.
///
/// A GitHub body is markdown, and a grouped changelog runs to dozens of
/// lines - printed raw it is both unreadable and long enough to push the
/// Download button off the sheet. [releaseNotesToPlainText] drops the syntax,
/// and only the first [releaseNotesCollapsedChars] are shown until the reader
/// asks for the rest, so the actions stay in view either way.
class _WhatsNew extends StatefulWidget {
  const _WhatsNew({required this.notes});

  final String notes;

  @override
  State<_WhatsNew> createState() => _WhatsNewState();
}

class _WhatsNewState extends State<_WhatsNew> {
  bool _expanded = false;

  /// The body, rendered once.
  ///
  /// This runs on the UI isolate, and the sheet rebuilds for every toggle
  /// tap, theme change and metrics change - rendering in `build` would pay
  /// for the whole body again each time.
  late String _text;

  @override
  void initState() {
    super.initState();
    _text = releaseNotesToPlainText(widget.notes);
  }

  @override
  void didUpdateWidget(_WhatsNew oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.notes != oldWidget.notes) {
      _text = releaseNotesToPlainText(widget.notes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = _text;
    // A release with no body (or one that was nothing but markup) says
    // nothing worth a heading.
    if (text.isEmpty) return const SizedBox.shrink();

    final collapsible = text.length > releaseNotesCollapsedChars;
    final shown = !collapsible || _expanded
        ? text
        : '${text.substring(0, releaseNotesCollapsedChars).trimRight()}\u2026';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(l10n.updateReleaseNotes, style: context.text.titleSmall),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: Text(shown, style: context.text.bodyMedium),
          ),
        ),
        if (collapsible)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? l10n.updateShowLess : l10n.updateShowMore,
              ),
            ),
          ),
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.status});

  final UpdateStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(appUpdateProvider.notifier);

    Future<void> later() async {
      await notifier.dismiss();
      if (context.mounted) await Navigator.of(context).maybePop();
    }

    Future<void> install() async {
      if (!await confirmInstall(context)) return;
      await notifier.install();
    }

    // While bytes are arriving the only thing worth offering is a way out:
    // "Later" would dismiss the release without stopping the transfer.
    if (status is UpdateDownloading) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: notifier.cancelDownload,
            child: Text(l10n.updateCancel),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(onPressed: later, child: Text(l10n.updateLater)),
        const SizedBox(width: 8),
        if (status is UpdateReady)
          FilledButton(onPressed: install, child: Text(l10n.updateInstall))
        else if (status is UpdateAvailable)
          FilledButton(
            onPressed: notifier.download,
            child: Text(l10n.updateDownload),
          ),
      ],
    );
  }
}
