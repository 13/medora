/// Medora - AIFA search bottom sheets.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/aifa_cache_service.dart';

/// Shows a modal bottom sheet to search the AIFA database by medication
/// name and pick a result. Returns the selected [AifaSearchResult], or
/// `null` if the sheet was dismissed without a selection.
Future<AifaSearchResult?> showAifaSearchSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final searchController = TextEditingController();
  List<AifaSearchResult> results = [];
  bool isSearching = false;

  return showModalBottomSheet<AifaSearchResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            _dragHandle(ctx),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.searchAifaByName,
                style: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.searchMedications,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: () async {
                            final query = searchController.text.trim();
                            if (query.length < 2) return;
                            setSheetState(() => isSearching = true);
                            try {
                              final r = await AifaCacheService.instance
                                  .searchByName(query);
                              setSheetState(() {
                                results = r;
                                isSearching = false;
                              });
                            } catch (_) {
                              setSheetState(() => isSearching = false);
                            }
                          },
                        ),
                ),
                onSubmitted: (query) async {
                  if (query.trim().length < 2) return;
                  setSheetState(() => isSearching = true);
                  try {
                    final r = await AifaCacheService.instance.searchByName(
                      query.trim(),
                    );
                    setSheetState(() {
                      results = r;
                      isSearching = false;
                    });
                  } catch (_) {
                    setSheetState(() => isSearching = false);
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                        isSearching ? '' : l10n.searchMedications,
                        style: TextStyle(color: ctx.colors.outline),
                      ),
                    )
                  : _resultList(results, scrollController: scrollController),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(searchController.dispose);
}

/// Shows a modal bottom sheet listing [results] to pick from (e.g. multiple
/// barcode matches). Returns the selected [AifaSearchResult], or `null` if
/// the sheet was dismissed without a selection.
Future<AifaSearchResult?> showAifaResultsPicker(
  BuildContext context,
  List<AifaSearchResult> results, {
  required String title,
}) {
  return showModalBottomSheet<AifaSearchResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          _dragHandle(ctx),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              title,
              style: Theme.of(
                ctx,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _resultList(results, scrollController: scrollController),
          ),
        ],
      ),
    ),
  );
}

Widget _dragHandle(BuildContext context) {
  return Container(
    margin: const EdgeInsets.only(top: 8),
    width: 40,
    height: 4,
    decoration: BoxDecoration(
      color: context.colors.outlineVariant,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

Widget _resultList(
  List<AifaSearchResult> results, {
  required ScrollController scrollController,
}) {
  return ListView.separated(
    controller: scrollController,
    itemCount: results.length,
    separatorBuilder: (_, _) => const Divider(height: 1),
    itemBuilder: (ctx, i) => _resultTile(ctx, results[i]),
  );
}

Widget _resultTile(BuildContext context, AifaSearchResult r) {
  return ListTile(
    title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (r.description.isNotEmpty)
          Text(
            r.description,
            style: const TextStyle(fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (r.activeIngredient != null)
          Text(
            r.activeIngredient!,
            style: TextStyle(
              fontSize: 11,
              color: context.colors.onSurfaceVariant,
            ),
          ),
        if (r.manufacturer != null)
          Text(
            r.manufacturer!,
            style: TextStyle(
              fontSize: 11,
              color: context.colors.onSurfaceVariant,
            ),
          ),
      ],
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.pop(context, r),
  );
}
