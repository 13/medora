/// Medora - Settings → Data: the cached AIFA medicine database tile.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/screens/settings/widgets/settings_group.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/register_freshness.dart';

/// Settings → Data: the offline AIFA database (download/update, last
/// download and the cached product count).
class AifaDatabaseTile extends ConsumerStatefulWidget {
  const AifaDatabaseTile({super.key});

  @override
  ConsumerState<AifaDatabaseTile> createState() => _AifaDatabaseTileState();
}

class _AifaDatabaseTileState extends ConsumerState<AifaDatabaseTile> {
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

    // The AIFA cache carries no source date, so its download date stands in.
    final freshness = registerFreshness(
      now: ref.read(nowProvider)(),
      lastSync: _lastSync,
      count: _count,
    );
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
            children: [
              Text(l10n.aifaDatabaseHint),
              Text(status),
              if (!_isSyncing && freshness.isStale)
                RegisterStaleWarning(freshness),
            ],
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
                    label: Text(
                      freshness.isStale
                          ? l10n.registerUpdateNow
                          : l10n.syncAifaDatabase,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
