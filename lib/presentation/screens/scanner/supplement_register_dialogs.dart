/// Medora - food-supplement register dialogs used by the scanner
///
/// The first-use download prompt (with a progress dialog) and the product
/// picker for a code shared by several register entries.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// Asks whether to download the register and downloads it with a progress
/// dialog. Returns true once the register is stored, false when the download
/// failed (offline, server error; the caller reports it) and null when the
/// user cancelled.
Future<bool?> confirmAndDownloadSupplementRegister(
  BuildContext context,
  SupplementRegistryService service,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.supplementRegister),
      content: Text(l10n.supplementRegisterDownloadPrompt),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.supplementRegisterDownload),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return null;
  final downloaded = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SupplementRegisterDownloadDialog(service: service),
  );
  return downloaded ?? false;
}

/// Runs [SupplementRegistryService.sync] while showing its progress; pops
/// with true on success and false on any error.
class SupplementRegisterDownloadDialog extends StatefulWidget {
  const SupplementRegisterDownloadDialog({super.key, required this.service});

  final SupplementRegistryService service;

  @override
  State<SupplementRegisterDownloadDialog> createState() =>
      _SupplementRegisterDownloadDialogState();
}

class _SupplementRegisterDownloadDialogState
    extends State<SupplementRegisterDownloadDialog> {
  double? _progress;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    var ok = false;
    try {
      await widget.service.sync(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      ok = true;
    } catch (e) {
      debugPrint('Supplement register download failed: $e');
    }
    if (mounted) Navigator.pop(context, ok);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l10n.supplementRegister),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.supplementRegisterDownloading),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
          ],
        ),
      ),
    );
  }
}

/// Asks whether to use [code], found as [product] (by [company]), in place
/// of the code as [read] that was not found (a lookup matched only another
/// OCR reading of it). True for Use; false for Cancel or when dismissed.
Future<bool> confirmAlternativeCode(
  BuildContext context, {
  required String read,
  required String code,
  required String product,
  String? company,
}) async {
  final l10n = AppLocalizations.of(context);
  final message = company == null || company.trim().isEmpty
      ? l10n.scanAlternativeCodeConfirmNoCompany(read, code, product)
      : l10n.scanAlternativeCodeConfirm(read, code, product, company);
  final use = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.scanAlternativeCodeUse),
        ),
      ],
    ),
  );
  return use ?? false;
}

/// Lets the user choose one of several register [entries] for one code.
Future<SupplementEntry?> showSupplementPicker(
  BuildContext context,
  List<SupplementEntry> entries,
) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<SupplementEntry>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: ctx.colors.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.eco_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.supplementSelectProduct,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${entries.length} ${l10n.results}',
                  style: TextStyle(
                    color: ctx.colors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              controller: scrollController,
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final entry = entries[i];
                return ListTile(
                  title: Text(
                    entry.product,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${entry.company} · ${entry.code}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(ctx, entry),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
