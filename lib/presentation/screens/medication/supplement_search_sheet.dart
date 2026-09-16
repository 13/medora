/// Medora - food-supplement register search sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// A modal search over the cached supplement register; returns the chosen
/// product, or null when dismissed. Requires the register to be cached —
/// the caller offers the download first
/// ([confirmAndDownloadSupplementRegister]).
Future<SupplementEntry?> showSupplementSearchSheet(
  BuildContext context,
  SupplementRegistryService service,
) {
  return showModalBottomSheet<SupplementEntry>(
    context: context,
    isScrollControlled: true,
    // showModalBottomSheet does not pad for the keyboard, and the field
    // autofocuses: without this the keyboard covers the lower results.
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _SupplementSearchSheet(service: service),
    ),
  );
}

/// The register's own minimum (shorter queries return nothing), so a
/// one-character query never reaches the database.
const _minQueryLength = 2;
const _debounce = Duration(milliseconds: 300);

class _SupplementSearchSheet extends StatefulWidget {
  const _SupplementSearchSheet({required this.service});

  final SupplementRegistryService service;

  @override
  State<_SupplementSearchSheet> createState() => _SupplementSearchSheetState();
}

class _SupplementSearchSheetState extends State<_SupplementSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounceTimer;

  List<SupplementEntry> _results = const [];
  bool _searching = false;

  /// Whether a search has completed for the current query — only then is an
  /// empty [_results] a "no results" answer rather than "not asked yet".
  bool _searched = false;

  /// Whether that search threw (a corrupt or unopenable register), which is
  /// an error to report rather than an empty result to believe.
  bool _failed = false;

  /// Guards against an earlier, slower search overwriting a later one.
  int _requestId = 0;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (query.length < _minQueryLength) {
      _requestId++;
      setState(() {
        _results = const [];
        _searching = false;
        _searched = false;
        _failed = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounceTimer = Timer(_debounce, () => _search(query));
  }

  Future<void> _search(String query) async {
    final id = ++_requestId;
    // Null means the search threw — told apart from an empty answer below.
    List<SupplementEntry>? found;
    try {
      found = await widget.service.searchByName(query);
    } catch (e) {
      debugPrint('Supplement register search failed: $e');
    }
    if (!mounted || id != _requestId) return;
    setState(() {
      _failed = found == null;
      _results = found ?? const [];
      _searching = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
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
                    l10n.searchSupplementByName,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: l10n.supplementSearchHint,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          const SizedBox(height: 8),
          // A slim bar, so a pending query never tears the list down.
          if (_searching)
            const LinearProgressIndicator(minHeight: 1)
          else
            const Divider(height: 1),
          Expanded(child: _body(ctx, l10n, scrollController)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ScrollController scrollController,
  ) {
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      if (!_searched) return const SizedBox.shrink();
      return Center(
        child: Text(
          _failed ? l10n.genericError : l10n.noResults,
          style: TextStyle(color: context.colors.outline),
        ),
      );
    }
    return ListView.separated(
      controller: scrollController,
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final entry = _results[i];
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
    );
  }
}
