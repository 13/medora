/// Medora - Settings → Data: the offline food-supplement register tile.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/services/register_freshness.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// Settings → Data: the offline food-supplement register (download/update,
/// last download, product count and the Ministry's "as of" date).
class SupplementRegisterTile extends ConsumerStatefulWidget {
  const SupplementRegisterTile({super.key});

  @override
  ConsumerState<SupplementRegisterTile> createState() =>
      _SupplementRegisterTileState();
}

class _SupplementRegisterTileState
    extends ConsumerState<SupplementRegisterTile> {
  bool _isSyncing = false;
  double? _progress;
  DateTime? _lastSync;
  DateTime? _sourceUpdated;
  int _count = 0;

  SupplementRegistryService get _service =>
      ref.read(supplementRegistryServiceProvider);

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final lastSync = await _service.lastSync();
      final count = await _service.count();
      final sourceUpdated = await _service.sourceUpdated();
      if (!mounted) return;
      setState(() {
        _lastSync = lastSync;
        _count = count;
        _sourceUpdated = sourceUpdated;
      });
    } catch (e) {
      debugPrint('Supplement register status unavailable: $e');
    }
  }

  Future<void> _sync() async {
    if (_isSyncing) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _isSyncing = true;
      _progress = null;
    });
    try {
      final count = await _service.sync(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _loadStatus();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.supplementRegisterSyncSuccess(count))),
      );
    } catch (e) {
      debugPrint('Supplement register download failed: $e');
      messenger.showSnackBar(SnackBar(content: Text(l10n.aifaSyncError)));
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lastSync = _lastSync;
    final sourceUpdated = _sourceUpdated;
    // The Ministry's "as of" date is what ages the register; the download
    // date only stands in when the meta file carried no date.
    final freshness = registerFreshness(
      now: ref.read(nowProvider)(),
      sourceUpdated: sourceUpdated,
      lastSync: lastSync,
      count: _count,
    );
    final status = _isSyncing
        ? l10n.supplementRegisterDownloading
        : lastSync != null && _count > 0
        ? '${l10n.aifaLastSync(lastSync.formatted)} · '
              '${NumberFormat.decimalPattern(Localizations.localeOf(context).toString()).format(_count)}'
        : l10n.aifaNeverSynced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.eco_outlined),
          title: Text(l10n.supplementRegister),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.supplementRegisterHint),
              Text(status),
              if (!_isSyncing && _count > 0 && sourceUpdated != null)
                Text(l10n.supplementRegisterUpdated(sourceUpdated.formatted)),
              if (!_isSyncing && freshness.isStale)
                RegisterStaleWarning(freshness),
            ],
          ),
          isThreeLine: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _isSyncing
              ? LinearProgressIndicator(value: _progress)
              : Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _sync,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      _count <= 0
                          ? l10n.supplementRegisterDownload
                          : freshness.isStale
                          ? l10n.registerUpdateNow
                          : l10n.supplementRegisterUpdate,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
