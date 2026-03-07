/// Medora - Medication Detail Screen
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class MedicationDetailScreen extends ConsumerWidget {
  const MedicationDetailScreen({super.key, required this.medicationId});

  final String medicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final medsAsync = ref.watch(medicationListProvider);

    return medsAsync.when(
      data: (medications) {
        final med = medications.where((m) => m.id == medicationId).firstOrNull;
        if (med == null) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.medication)),
            body: EmptyStateWidget(
              icon: Icons.error_outline,
              title: l10n.medicationNotFound,
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(med.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () =>
                    context.push('/medications/${med.id}/edit'),
              ),
              PopupMenuButton(
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: med.isArchived ? 'unarchive' : 'archive',
                    child: ListTile(
                      leading: Icon(
                        med.isArchived
                            ? Icons.unarchive
                            : Icons.archive,
                        color: Colors.orange,
                      ),
                      title: Text(
                        med.isArchived
                            ? l10n.unarchive
                            : l10n.archive,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: const Icon(Icons.delete, color: Colors.red),
                      title: Text(l10n.delete,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
                onSelected: (value) async {
                  if (value == 'archive') {
                    ref
                        .read(medicationListProvider.notifier)
                        .archiveMedication(med.id);
                    if (context.mounted) context.pop();
                  } else if (value == 'unarchive') {
                    ref
                        .read(medicationListProvider.notifier)
                        .unarchiveMedication(med.id);
                    if (context.mounted) context.pop();
                  } else if (value == 'delete') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(l10n.deleteMedication),
                        content: Text(
                          l10n.deleteMedicationConfirm(med.name),
                        ),
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
                    if (confirm == true && context.mounted) {
                      ref
                          .read(medicationListProvider.notifier)
                          .deleteMedication(med.id);
                      context.pop();
                    }
                  }
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status badges
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
              const SizedBox(height: 20),

              // Quantity controls
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.quantity,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            '${med.quantity}${med.quantityUnit != null ? ' ${med.quantityUnit}' : ''}',
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton.filled(
                            onPressed: med.quantity > 0
                                ? () => ref
                                    .read(medicationListProvider.notifier)
                                    .updateQuantity(med.id, -1)
                                : null,
                            icon: const Icon(Icons.remove),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            onPressed: () => ref
                                .read(medicationListProvider.notifier)
                                .updateQuantity(med.id, 1),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Details card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.details,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Divider(),
                      _DetailRow(
                        label: l10n.activeIngredients,
                        value: med.activeIngredients.isNotEmpty
                            ? med.activeIngredients.join(', ')
                            : '—',
                      ),
                      if (med.description != null && med.description!.isNotEmpty)
                        _DetailRow(
                          label: l10n.medicationDescription,
                          value: med.description!,
                        ),
                      _DetailRow(
                        label: l10n.category,
                        value: med.category != null
                            ? AppConstants.categoryLabel(l10n, med.category!)
                            : '—',
                      ),
                      if (med.manufacturer != null && med.manufacturer!.isNotEmpty)
                        _DetailRow(
                          label: l10n.manufacturerLabel,
                          value: med.manufacturer!,
                        ),
                      if (med.form != null && med.form!.isNotEmpty)
                        _DetailRow(
                          label: l10n.formLabel,
                          value: med.form!,
                        ),
                      if (med.atcCode != null && med.atcCode!.isNotEmpty)
                        _DetailRow(
                          label: l10n.atcCodeLabel,
                          value: med.atcCode!,
                        ),
                      // Symptom tags
                      if (med.symptoms.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 140,
                                child: Text(
                                  l10n.treatsSymptoms,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: med.symptoms.map((s) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.teal.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(s,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.teal)),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Patient tags
                      if (med.patientTags.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 140,
                                child: Text(
                                  l10n.patientTagsField,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: med.patientTags.map((t) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.purple.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(t,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.purple)),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      _DetailRow(
                        label: l10n.purchaseDate,
                        value: med.purchaseDate.formattedOr(),
                      ),
                      _DetailRow(
                        label: l10n.expiryDate,
                        value: med.expiryDate.formattedOr(),
                      ),
                      _DetailRow(
                        label: l10n.storageLocation,
                        value: med.storageLocation != null
                            ? AppConstants.storageLabel(l10n, med.storageLocation!)
                            : '—',
                      ),
                      _DetailRow(
                        label: l10n.barcode,
                        value: med.barcode ?? '—',
                      ),
                      _DetailRow(
                        label: l10n.minimumStock,
                        value: '${med.minimumStockLevel}',
                      ),
                    ],
                  ),
                ),
              ),

              // Notes
              if (med.notes != null && med.notes!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.notes,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(med.notes!),
                      ],
                    ),
                  ),
                ),
              ],

              // Photo (at bottom)
              if (med.imagePath != null && File(med.imagePath!).existsSync()) ...[
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => Dialog(
                        backgroundColor: Colors.transparent,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.file(
                              File(med.imagePath!),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: Hero(
                    tag: 'med_photo_${med.id}',
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.file(
                          File(med.imagePath!),
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(title: Text(l10n.medication)),
        body: const LoadingWidget(),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(l10n.medication)),
        body: ErrorDisplayWidget(
          message: e.toString(),
          onRetry: () =>
              ref.read(medicationListProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }
}


