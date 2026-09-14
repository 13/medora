/// Medora - Medication List Screen
library;

import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Filter options for medication list.
enum MedicationFilter { all, needsAttention, archived }

class MedicationListScreen extends ConsumerStatefulWidget {
  const MedicationListScreen({super.key});

  @override
  ConsumerState<MedicationListScreen> createState() => _MedicationListScreenState();
}

class _MedicationListScreenState extends ConsumerState<MedicationListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  MedicationFilter _filter = MedicationFilter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Medication> _applyFilter(List<Medication> medications) {
    var filtered = medications;

    // Apply search query
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered.where((m) {
        return m.name.toLowerCase().contains(query) ||
            (m.manufacturer ?? '').toLowerCase().contains(query) ||
            m.patientTags.any((p) => p.toLowerCase().contains(query)) ||
            m.symptoms.any((s) => s.toLowerCase().contains(query)) ||
            (m.notes ?? '').toLowerCase().contains(query);
      }).toList();
    }

    // Apply status filter
    return switch (_filter) {
      // Exclude archived from "All" view per user request.
      MedicationFilter.all => filtered.where((m) => !m.isArchived).toList(),
      MedicationFilter.needsAttention => filtered.where((m) {
          if (m.isArchived) return false;
          final isLowStock = m.quantity <= m.minimumStockLevel;
          final isExpired = m.expiryDate?.isPast ?? false;
          return isLowStock || isExpired || m.isExpiringSoon();
        }).toList(),
      MedicationFilter.archived => filtered.where((m) => m.isArchived).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final medicationsAsync = ref.watch(medicationListProvider);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.searchMedications,
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text(l10n.medications),
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
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                _FilterChip(
                  label: l10n.all,
                  selected: _filter == MedicationFilter.all,
                  onTap: () => setState(() => _filter = MedicationFilter.all),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: '${l10n.lowStock} · ${l10n.expiringSoon}',
                  selected: _filter == MedicationFilter.needsAttention,
                  onTap: () => setState(() => _filter = MedicationFilter.needsAttention),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.archived,
                  selected: _filter == MedicationFilter.archived,
                  onTap: () => setState(() => _filter = MedicationFilter.archived),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Medication list
          Expanded(
            child: AsyncValueView<List<Medication>>(
              value: medicationsAsync,
              onRetry: () async => ref.read(medicationListProvider.notifier).refresh(),
              emptyWhen: (medications) => medications.isEmpty,
              empty: EmptyStateWidget(
                icon: Icons.inventory_2_outlined,
                title: l10n.noMedicationsYet,
                subtitle: l10n.addFirstMedication,
                actionLabel: l10n.addMedicationButton,
                onAction: () => context.push(AppRoutes.addMedication),
              ),
              data: (medications) {
                final filtered = _applyFilter(medications);
                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off, size: 48, color: context.colors.outline),
                        const SizedBox(height: 8),
                        Text(l10n.noResults, style: TextStyle(color: context.colors.onSurfaceVariant)),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.read(medicationListProvider.notifier).refresh();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final med = filtered[index];
                      // Providing a unique Key is essential for Slidable items 
                      // to prevent layout errors when items are removed/reordered.
                      return Slidable(
                        key: ValueKey(med.id),
                        endActionPane: ActionPane(
                          motion: const ScrollMotion(),
                          children: [
                            if (!med.isArchived)
                              SlidableAction(
                                onPressed: (_) async {
                                  await ref.read(medicationListProvider.notifier).archiveMedication(med.id);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l10n.archived),
                                        action: SnackBarAction(
                                          label: l10n.undo,
                                          onPressed: () => ref
                                              .read(medicationListProvider.notifier)
                                              .unarchiveMedication(med.id),
                                        ),
                                      ),
                                    );
                                  }
                                },
                                backgroundColor: context.colors.tertiaryContainer,
                                foregroundColor: context.colors.onTertiaryContainer,
                                icon: Icons.archive,
                                label: l10n.archive,
                              ),
                            if (med.isArchived)
                              SlidableAction(
                                onPressed: (_) {
                                  ref.read(medicationListProvider.notifier).unarchiveMedication(med.id);
                                },
                                backgroundColor: context.medora.success,
                                foregroundColor: context.medora.onSuccess,
                                icon: Icons.unarchive,
                                label: l10n.unarchive,
                              ),
                            SlidableAction(
                              onPressed: (_) async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.deleteMedication),
                                    content: Text(l10n.deleteMedicationConfirm(med.name)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: Text(l10n.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: Text(l10n.delete, style: TextStyle(color: context.colors.error)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  ref.read(medicationListProvider.notifier).deleteMedication(med.id);
                                }
                              },
                              backgroundColor: context.colors.error,
                              foregroundColor: context.colors.onError,
                              icon: Icons.delete,
                              label: l10n.delete,
                            ),
                          ],
                        ),
                        child: _MedicationTile(med: med),
                      );
                    },
                  ),
                );
              },
              loading: LoadingWidget(message: l10n.loadingMedications),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.addMedication),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _MedicationTile extends StatelessWidget {
  const _MedicationTile({required this.med});
  final Medication med;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isLowStock = med.quantity <= med.minimumStockLevel;
    final isExpired = med.expiryDate?.isPast ?? false;
    final now = DateTime.now();

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isExpired
            ? context.medora.dangerContainer
            : isLowStock
                ? context.medora.warningContainer
                : context.colors.primaryContainer,
        child: Icon(
          Icons.medication,
          color: isExpired
              ? context.medora.onDangerContainer
              : isLowStock
                  ? context.medora.onWarningContainer
                  : context.colors.onPrimaryContainer,
        ),
      ),
      title: Text(
        med.name,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Replace manufacturer with symptom ("treats") tags
          if (med.symptoms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: med.symptoms.take(3).map((s) => TagChip(label: s, fontSize: 10)).toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Row(
              children: [
                StockIndicator(
                  quantity: med.quantity,
                  minimumStock: med.minimumStockLevel,
                  isExpired: isExpired,
                ),
                if (med.expiryDate != null) ...[
                  Text(' · ', style: TextStyle(color: context.colors.onSurfaceVariant)),
                  Text(
                    med.expiryDate!.year == now.year
                        ? med.expiryDate!.shortFormatted
                        : med.expiryDate!.formatted,
                    style: TextStyle(
                      color: isExpired ? context.medora.danger : context.colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (med.isArchived) ...[
                  Text(' · ', style: TextStyle(color: context.colors.onSurfaceVariant)),
                  Icon(Icons.archive, size: 12, color: context.colors.onSurfaceVariant),
                ],
              ],
            ),
          ),
          if (med.patientTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: med.patientTags.map((t) => TagChip(label: t, icon: Icons.person)).toList(),
              ),
            ),
        ],
      ),
      trailing: med.category != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: context.colors.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                AppConstants.categoryLabel(l10n, med.category!),
                style: TextStyle(fontSize: 10, color: context.colors.onSecondaryContainer),
              ),
            )
          : null,
      isThreeLine: true,
      onTap: () => context.push('/medications/${med.id}'),
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
