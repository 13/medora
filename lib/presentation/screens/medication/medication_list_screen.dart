/// Medora - Medication List Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sync_icon_button.dart';

/// Filter options for medication list.
enum MedicationFilter { all, inStock, lowStock, expired, archived }

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
      MedicationFilter.inStock =>
        filtered.where((m) => m.quantity > m.minimumStockLevel && !m.isArchived).toList(),
      MedicationFilter.lowStock =>
        filtered.where((m) => m.quantity <= m.minimumStockLevel && !m.isArchived).toList(),
      MedicationFilter.expired => filtered.where((m) {
          if (m.isArchived) return false;
          if (m.expiryDate == null) return false;
          return m.expiryDate!.isPast;
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
                  label: l10n.lowStock,
                  selected: _filter == MedicationFilter.lowStock,
                  onTap: () => setState(() => _filter = MedicationFilter.lowStock),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.expired,
                  selected: _filter == MedicationFilter.expired,
                  onTap: () => setState(() => _filter = MedicationFilter.expired),
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
            child: medicationsAsync.when(
              data: (medications) {
                final filtered = _applyFilter(medications);
                if (medications.isEmpty) {
                  return EmptyStateWidget(
                    icon: Icons.inventory_2_outlined,
                    title: l10n.noMedicationsYet,
                    subtitle: l10n.addFirstMedication,
                    actionLabel: l10n.addMedicationButton,
                    onAction: () => context.push(AppRoutes.addMedication),
                  );
                }

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 8),
                        Text(l10n.noResults, style: TextStyle(color: Colors.grey[500])),
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
                                onPressed: (_) {
                                  ref.read(medicationListProvider.notifier).archiveMedication(med.id);
                                },
                                backgroundColor: Colors.blueGrey,
                                foregroundColor: Colors.white,
                                icon: Icons.archive,
                                label: l10n.archive,
                              ),
                            if (med.isArchived)
                              SlidableAction(
                                onPressed: (_) {
                                  ref.read(medicationListProvider.notifier).unarchiveMedication(med.id);
                                },
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
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
                                        child: Text(l10n.delete, style: const TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  ref.read(medicationListProvider.notifier).deleteMedication(med.id);
                                }
                              },
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
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
              loading: () => LoadingWidget(message: l10n.loadingMedications),
              error: (error, stackTrace) => ErrorDisplayWidget(
                message: error.toString(),
                onRetry: () => ref.read(medicationListProvider.notifier).refresh(),
              ),
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
        backgroundColor: (isExpired || isLowStock)
            ? (isExpired ? Colors.red[50] : Colors.orange[50])
            : AppTheme.primaryColor.withValues(alpha: 0.1),
        child: Icon(
          Icons.medication,
          color: (isExpired || isLowStock)
              ? (isExpired ? Colors.red : Colors.orange)
              : AppTheme.primaryColor,
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
                  const Text(' · ', style: TextStyle(color: Colors.grey)),
                  Text(
                    med.expiryDate!.year == now.year
                        ? med.expiryDate!.shortFormatted
                        : med.expiryDate!.formatted,
                    style: TextStyle(
                      color: isExpired ? Colors.red : Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                ],
                if (med.isArchived) ...[
                  const Text(' · ', style: TextStyle(color: Colors.grey)),
                  Icon(Icons.archive, size: 12, color: Colors.blueGrey[300]),
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
                color: Colors.blueGrey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                AppConstants.categoryLabel(l10n, med.category!),
                style: TextStyle(fontSize: 10, color: Colors.blueGrey[700]),
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
