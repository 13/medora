/// Medora - Treatment List Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sync_icon_button.dart';

/// Filter options for treatment list.
enum TreatmentFilter { active, ended, all }

class TreatmentListScreen extends ConsumerStatefulWidget {
  const TreatmentListScreen({super.key});

  @override
  ConsumerState<TreatmentListScreen> createState() =>
      _TreatmentListScreenState();
}

class _TreatmentListScreenState extends ConsumerState<TreatmentListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  TreatmentFilter _filter = TreatmentFilter.active;

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
          const SyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
          if (kIsWeb)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: l10n.signOut,
              onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
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
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.all,
                  selected: _filter == TreatmentFilter.all,
                  onTap: () => setState(() => _filter = TreatmentFilter.all),
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
                        child: _TreatmentTile(treatment: t),
                      );
                    },
                  ),
                );
              },
              loading: () => LoadingWidget(message: l10n.loadingTreatments),
              error: (error, stackTrace) => ErrorDisplayWidget(
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

class _TreatmentTile extends ConsumerWidget {
  const _TreatmentTile({required this.treatment});
  final Treatment treatment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prescriptionsAsync = ref.watch(prescriptionsByTreatmentProvider(treatment.id));

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
        child: const Icon(
          Icons.healing,
          color: AppTheme.primaryColor,
        ),
      ),
      title: Text(
        treatment.name,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Symptoms (max 3)
          if (treatment.symptomTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Wrap(
                spacing: 4,
                runSpacing: 2,
                children: treatment.symptomTags.take(3).map((s) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(s,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.orange)),
                  );
                }).toList(),
              ),
            ),
          
          // User (Patient tags)
          if (treatment.patientTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      treatment.patientTags.join(', '),
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Status and Started on
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: treatment.isActive
                        ? AppTheme.successColor.withValues(alpha: 0.15)
                        : Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    treatment.isActive ? l10n.active : l10n.ended,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: treatment.isActive
                          ? AppTheme.successColor
                          : Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.startedOn(treatment.startDate.shortFormatted),
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      trailing: prescriptionsAsync.when(
        data: (prescriptions) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${prescriptions.length}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              l10n.prescriptions,
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        loading: () => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (error, _) => const SizedBox.shrink(),
      ),
      isThreeLine: true,
      onTap: () => context.push('/treatments/${treatment.id}'),
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
