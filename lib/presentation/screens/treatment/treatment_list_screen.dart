/// Medora - Treatment List Screen
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Filter options for treatment list.
enum TreatmentFilter { all, active, ended }

class TreatmentListScreen extends ConsumerStatefulWidget {
  const TreatmentListScreen({super.key});

  @override
  ConsumerState<TreatmentListScreen> createState() =>
      _TreatmentListScreenState();
}

class _TreatmentListScreenState extends ConsumerState<TreatmentListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  TreatmentFilter _filter = TreatmentFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Treatment> _applyFilter(List<Treatment> treatments) {
    var filtered = treatments;

    // Apply search query
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered.where((t) {
        return t.name.toLowerCase().contains(query) ||
            t.symptomTags.any((s) => s.toLowerCase().contains(query)) ||
            t.patientTags.any((p) => p.toLowerCase().contains(query)) ||
            (t.notes ?? '').toLowerCase().contains(query);
      }).toList();
    }

    // Apply status filter
    return switch (_filter) {
      TreatmentFilter.all => filtered,
      TreatmentFilter.active => filtered.where((t) => t.isActive).toList(),
      TreatmentFilter.ended => filtered.where((t) => !t.isActive).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(treatmentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.searchTreatments,
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text(l10n.treatments),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchController.clear();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                _FilterChip(
                  label: l10n.all,
                  selected: _filter == TreatmentFilter.all,
                  onTap: () => setState(() => _filter = TreatmentFilter.all),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.active,
                  selected: _filter == TreatmentFilter.active,
                  onTap: () =>
                      setState(() => _filter = TreatmentFilter.active),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.ended,
                  selected: _filter == TreatmentFilter.ended,
                  onTap: () =>
                      setState(() => _filter = TreatmentFilter.ended),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Treatment list
          Expanded(
            child: treatmentsAsync.when(
              data: (treatments) {
                final filtered = _applyFilter(treatments);
                if (treatments.isEmpty) {
                  return EmptyStateWidget(
                    icon: Icons.healing_outlined,
                    title: l10n.noTreatmentsYet,
                    subtitle: l10n.createTreatmentPlan,
                    actionLabel: l10n.addTreatment,
                    onAction: () => context.push(AppRoutes.addTreatment),
                  );
                }

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off,
                            size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 8),
                        Text(l10n.noResults,
                            style: TextStyle(color: Colors.grey[500])),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.read(treatmentListProvider.notifier).refresh();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final t = filtered[index];
                      return Slidable(
                        endActionPane: ActionPane(
                          motion: const ScrollMotion(),
                          children: [
                            if (t.isActive)
                              SlidableAction(
                                onPressed: (_) {
                                  ref
                                      .read(treatmentListProvider.notifier)
                                      .endTreatment(t.id);
                                },
                                backgroundColor: Colors.orange,
                                foregroundColor: Colors.white,
                                icon: Icons.stop_circle,
                                label: l10n.end,
                              ),
                            if (!t.isActive)
                              SlidableAction(
                                onPressed: (_) {
                                  ref
                                      .read(treatmentListProvider.notifier)
                                      .deleteTreatment(t.id);
                                },
                                backgroundColor: Colors.blueGrey,
                                foregroundColor: Colors.white,
                                icon: Icons.archive,
                                label: l10n.archive,
                              ),
                            SlidableAction(
                              onPressed: (_) async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.deleteTreatment),
                                    content: Text(
                                      l10n.deleteTreatmentConfirm(t.name),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(l10n.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(l10n.delete,
                                            style: const TextStyle(
                                                color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  ref
                                      .read(treatmentListProvider.notifier)
                                      .deleteTreatment(t.id);
                                }
                              },
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              icon: Icons.delete,
                              label: l10n.delete,
                            ),
                          ],
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.isActive
                                ? AppTheme.primaryColor
                                : Colors.grey,
                            child: Icon(
                              t.isActive
                                  ? Icons.healing
                                  : Icons.healing_outlined,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            t.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (t.patientTags.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: t.patientTags.map((p) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primaryColor
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(p,
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.primaryColor,
                                                fontWeight:
                                                    FontWeight.w500)),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              if (t.symptomTags.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: t.symptomTags.map((s) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.orange
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(s,
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.orange)),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: t.isActive
                                          ? AppTheme.successColor
                                              .withValues(alpha: 0.15)
                                          : Colors.grey
                                              .withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      t.isActive ? l10n.active : l10n.ended,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: t.isActive
                                            ? AppTheme.successColor
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.startedOn(
                                        t.startDate.shortFormatted),
                                    style: TextStyle(
                                        color: Colors.grey[500],
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          onTap: () => context.push('/treatments/${t.id}'),
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => LoadingWidget(message: l10n.loadingTreatments),
              error: (error, _) => ErrorDisplayWidget(
                message: error.toString(),
                onRetry: () =>
                    ref.read(treatmentListProvider.notifier).refresh(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.addTreatment),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}
