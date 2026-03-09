/// Medora - Medication List Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sync_icon_button.dart';

class MedicationListScreen extends ConsumerStatefulWidget {
  const MedicationListScreen({super.key});

  @override
  ConsumerState<MedicationListScreen> createState() =>
      _MedicationListScreenState();
}

class _MedicationListScreenState extends ConsumerState<MedicationListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  bool _showArchived = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final AsyncValue<List<Medication>> medicationsAsync;
    if (_showArchived) {
      medicationsAsync = ref.watch(archivedMedicationsProvider);
    } else if (_isSearching) {
      medicationsAsync = ref.watch(medicationSearchProvider);
    } else {
      medicationsAsync = ref.watch(medicationListProvider);
    }

    return Scaffold(
      appBar: AppBar(
        leading: _showArchived
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _showArchived = false),
              )
            : null,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.searchMedications,
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (value) {
                  ref.read(medicationSearchQueryProvider.notifier).set(value);
                },
              )
            : Text(_showArchived ? l10n.archivedMedications : l10n.medications),
        actions: [
          if (!_showArchived)
            IconButton(
              icon: Icon(_isSearching ? Icons.close : Icons.search),
              onPressed: () {
                setState(() {
                  _isSearching = !_isSearching;
                  if (!_isSearching) {
                    _searchController.clear();
                    ref.read(medicationSearchQueryProvider.notifier).set('');
                  }
                });
              },
            ),
          if (!_showArchived)
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: l10n.showArchived,
              onPressed: () {
                setState(() {
                  _showArchived = true;
                  _isSearching = false;
                  _searchController.clear();
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => context.push(AppRoutes.scanner),
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
      body: medicationsAsync.when(
        data: (medications) {
          if (medications.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.medication_outlined,
              title: _showArchived ? l10n.archivedMedications : l10n.noMedicationsYet,
              subtitle: _showArchived ? "" : l10n.addFirstMedication,
              actionLabel: _showArchived ? l10n.medications : l10n.addMedicationButton,
              onAction: () {
                if (_showArchived) {
                  setState(() => _showArchived = false);
                } else {
                  context.push(AppRoutes.addMedication);
                }
              },
            );
          }

          // Group medications by category
          final grouped = <String, List<Medication>>{};
          for (final med in medications) {
            final key = med.category ?? '_uncategorized';
            (grouped[key] ??= []).add(med);
          }

          // Sort category keys: known categories first, then uncategorized
          final sortedKeys = grouped.keys.toList()
            ..sort((a, b) {
              if (a == '_uncategorized') return 1;
              if (b == '_uncategorized') return -1;
              return a.compareTo(b);
            });

          return RefreshIndicator(
            onRefresh: () async {
              ref.read(medicationListProvider.notifier).refresh();
            },
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: sortedKeys.length,
              itemBuilder: (context, sectionIndex) {
                final catKey = sortedKeys[sectionIndex];
                final meds = grouped[catKey]!;
                final catLabel = catKey == '_uncategorized'
                    ? l10n.uncategorized
                    : AppConstants.categoryLabel(l10n, catKey);

                return ExpansionTile(
                  key: PageStorageKey('cat_$catKey'),
                  initiallyExpanded: true,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  collapsedBackgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  leading: Icon(_getCategoryIcon(catKey),
                      size: 18, color: _getCategoryColor(catKey)),
                  title: Row(
                    children: [
                      Text(
                        catLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: _getCategoryColor(catKey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '(${meds.length})',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                  children: meds
                      .map((med) =>
                          _buildMedicationTile(context, l10n, med))
                      .toList(),
                );
              },
            ),
          );
        },
        loading: () => LoadingWidget(message: l10n.loadingMedications),
        error: (error, _) => ErrorDisplayWidget(
          message: error.toString(),
          onRetry: () =>
              ref.read(medicationListProvider.notifier).refresh(),
        ),
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton(
              onPressed: () => context.push(AppRoutes.addMedication),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildMedicationTile(
      BuildContext context, AppLocalizations l10n, Medication med) {
    return Slidable(
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        children: [
          SlidableAction(
            onPressed: (_) {
              context.push('/medications/${med.id}/edit');
            },
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
            icon: Icons.edit,
            label: l10n.edit,
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
                      child: Text(l10n.delete,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                ref
                    .read(medicationListProvider.notifier)
                    .deleteMedication(med.id);
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
        title: Text(
          med.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Active ingredients as small chips
            if (med.activeIngredients.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  med.activeIngredients.join(', '),
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ),
            // Symptom tags
            if (med.symptoms.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: med.symptoms.map((s) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(s,
                          style: const TextStyle(
                              fontSize: 10, color: Colors.teal)),
                    );
                  }).toList(),
                ),
              ),
            // Patient tags
            if (med.patientTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 4,
                  children: med.patientTags.map((t) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(t,
                          style: const TextStyle(
                              fontSize: 10, color: Colors.purple)),
                    );
                  }).toList(),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                ExpiryBadge(expiryDate: med.expiryDate),
                const SizedBox(width: 8),
                StockIndicator(
                  quantity: med.quantity,
                  minimumStock: med.minimumStockLevel,
                ),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        onTap: () => context.push('/medications/${med.id}'),
      ),
    );
  }

  IconData _getCategoryIcon(String? category) {
    switch (category) {
      case 'painkiller':
        return Icons.healing;
      case 'antibiotic':
        return Icons.science;
      case 'antihistamine':
        return Icons.masks;
      case 'vitamin':
        return Icons.spa;
      case 'supplement':
        return Icons.energy_savings_leaf;
      case 'cold_flu':
        return Icons.thermostat;
      case 'digestive':
        return Icons.monitor_heart;
      case 'skin_care':
        return Icons.dry_cleaning;
      case 'eye_care':
        return Icons.visibility;
      case 'first_aid':
        return Icons.medical_services;
      default:
        return Icons.medication;
    }
  }

  Color _getCategoryColor(String? category) {
    switch (category) {
      case 'painkiller':
        return Colors.red[400]!;
      case 'antibiotic':
        return Colors.orange[400]!;
      case 'antihistamine':
        return Colors.amber[600]!;
      case 'vitamin':
        return Colors.green[400]!;
      case 'supplement':
        return Colors.green[600]!;
      case 'cold_flu':
        return Colors.blue[400]!;
      case 'digestive':
        return Colors.purple[400]!;
      case 'skin_care':
        return Colors.pink[300]!;
      case 'eye_care':
        return Colors.cyan[400]!;
      case 'first_aid':
        return Colors.red[600]!;
      default:
        return Colors.teal[400]!;
    }
  }
}
