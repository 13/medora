/// Medora - Treatment Detail Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:uuid/uuid.dart';

class TreatmentDetailScreen extends ConsumerStatefulWidget {
  const TreatmentDetailScreen({super.key, required this.treatmentId});

  final String treatmentId;

  @override
  ConsumerState<TreatmentDetailScreen> createState() =>
      _TreatmentDetailScreenState();
}

class _TreatmentDetailScreenState
    extends ConsumerState<TreatmentDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(treatmentListProvider);
    final prescriptionsAsync =
        ref.watch(prescriptionsByTreatmentProvider(widget.treatmentId));

    return treatmentsAsync.when(
      data: (treatments) {
        final treatment =
            treatments.where((t) => t.id == widget.treatmentId).firstOrNull;
        if (treatment == null) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.treatment)),
            body: EmptyStateWidget(
              icon: Icons.error_outline,
              title: l10n.treatmentNotFound,
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(treatment.name),
            actions: [
              // Edit button
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () =>
                    context.push('/treatments/${treatment.id}/edit'),
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'end':
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(l10n.endTreatment),
                          content: Text(
                            l10n.endTreatmentConfirm(treatment.name),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(l10n.cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(l10n.endTreatment),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        ref
                            .read(treatmentListProvider.notifier)
                            .endTreatment(treatment.id);
                      }
                    case 'archive':
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(l10n.archiveTreatment),
                          content: Text(
                            l10n.archiveTreatmentConfirm(treatment.name),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(l10n.cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(l10n.archive),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true && context.mounted) {
                        ref
                            .read(treatmentListProvider.notifier)
                            .endTreatment(treatment.id);
                        if (context.mounted) context.pop();
                      }
                    case 'delete':
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(l10n.deleteTreatment),
                          content: Text(
                            l10n.deleteTreatmentConfirm(treatment.name),
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
                            .read(treatmentListProvider.notifier)
                            .deleteTreatment(treatment.id);
                        if (context.mounted) context.pop();
                      }
                  }
                },
                itemBuilder: (ctx) => [
                  if (treatment.isActive)
                    PopupMenuItem(
                      value: 'end',
                      child: ListTile(
                        leading: const Icon(Icons.stop_circle,
                            color: Colors.orange),
                        title: Text(l10n.endTreatment),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (!treatment.isActive)
                    PopupMenuItem(
                      value: 'archive',
                      child: ListTile(
                        leading: const Icon(Icons.archive,
                            color: Colors.blueGrey),
                        title: Text(l10n.archiveTreatment),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: const Icon(Icons.delete, color: Colors.red),
                      title: Text(l10n.deleteTreatment),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status card
              Card(
                color: treatment.isActive
                    ? AppTheme.primaryColor.withValues(alpha: 0.1)
                    : Colors.grey.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            treatment.isActive
                                ? Icons.healing
                                : Icons.healing_outlined,
                            color: treatment.isActive
                                ? AppTheme.primaryColor
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            treatment.isActive ? l10n.active : l10n.ended,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: treatment.isActive
                                  ? AppTheme.primaryColor
                                  : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (treatment.patientTags.isNotEmpty) ...[
                        Text(l10n.treatmentPatientTags,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12)),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.patientTags.map((t) {
                            return Chip(
                              label: Text(t, style: const TextStyle(fontSize: 12)),
                              avatar: const Icon(Icons.person, size: 16),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (treatment.symptomTags.isNotEmpty) ...[
                        Text(l10n.treatmentSymptomTags,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12)),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.symptomTags.map((s) {
                            return Chip(
                              label: Text(s, style: const TextStyle(fontSize: 12)),
                              backgroundColor: Colors.orange.withValues(alpha: 0.12),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l10n.startDate,
                                    style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12)),
                                Text(treatment.startDate.formatted),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l10n.endDate,
                                    style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12)),
                                Text(treatment.endDate
                                    .formattedOr(l10n.ongoing)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (treatment.notes != null &&
                          treatment.notes!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(l10n.notes,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(treatment.notes!),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Prescriptions section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l10n.prescriptions,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (treatment.isActive)
                    TextButton.icon(
                      onPressed: () => _showPrescriptionDialog(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.add),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              prescriptionsAsync.when(
                data: (prescriptions) {
                  if (prescriptions.isEmpty) {
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.medication_outlined,
                                size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 8),
                            Text(l10n.noPrescriptionsYet),
                            if (treatment.isActive) ...[
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () =>
                                    _showPrescriptionDialog(context),
                                child: Text(l10n.addPrescription),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }

                  return Column(
                    children: prescriptions.map((p) {
                      return Dismissible(
                        key: ValueKey(p.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Colors.red,
                          child: const Icon(Icons.delete,
                              color: Colors.white),
                        ),
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(l10n.deletePrescription),
                              content: Text(
                                  l10n.deletePrescriptionConfirm),
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
                        },
                        onDismissed: (_) async {
                          final repo =
                              ref.read(prescriptionRepositoryProvider);
                          await repo.deletePrescription(p.id);
                          ref.invalidate(
                              prescriptionsByTreatmentProvider(
                                  widget.treatmentId));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text(l10n.prescriptionDeleted)),
                            );
                          }
                        },
                        child: Card(
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: AppTheme.primaryColor,
                              child: Icon(Icons.medication,
                                  color: Colors.white, size: 20),
                            ),
                            title: Text(
                              p.medicationName ?? l10n.unknownMedication,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_prescriptionSummary(l10n, p)),
                                if (!p.isActive)
                                  Container(
                                    margin: const EdgeInsets.only(top: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(l10n.done, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                  ),
                                if (p.notes != null && p.notes!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      p.notes!,
                                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: ListTile(
                                    leading: const Icon(Icons.edit, size: 20),
                                    title: Text(l10n.edit),
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                if (p.isActive)
                                  PopupMenuItem(
                                    value: 'deactivate',
                                    child: ListTile(
                                      leading: const Icon(Icons.pause_circle_outline, size: 20),
                                      title: Text(l10n.deactivatePrescription),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                if (!p.isActive)
                                  PopupMenuItem(
                                    value: 'reactivate',
                                    child: ListTile(
                                      leading: const Icon(Icons.play_circle_outline, size: 20, color: Colors.green),
                                      title: Text(l10n.reactivatePrescription, style: const TextStyle(color: Colors.green)),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    leading: const Icon(Icons.delete, size: 20, color: Colors.red),
                                    title: Text(l10n.delete, style: const TextStyle(color: Colors.red)),
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  _showPrescriptionDialog(context, existing: p);
                                } else if (action == 'deactivate') {
                                  final repo = ref.read(prescriptionRepositoryProvider);
                                  await repo.deactivatePrescription(p.id);
                                  ref.invalidate(prescriptionsByTreatmentProvider(widget.treatmentId));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(l10n.prescriptionDeactivated)),
                                    );
                                  }
                                } else if (action == 'reactivate') {
                                  final repo = ref.read(prescriptionRepositoryProvider);
                                  await repo.reactivatePrescription(p.id);
                                  ref.invalidate(prescriptionsByTreatmentProvider(widget.treatmentId));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(l10n.prescriptionReactivated)),
                                    );
                                  }
                                } else if (action == 'delete') {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text(l10n.deletePrescription),
                                      content: Text(l10n.deletePrescriptionConfirm),
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
                                    final repo = ref.read(prescriptionRepositoryProvider);
                                    await repo.deletePrescription(p.id);
                                    ref.invalidate(prescriptionsByTreatmentProvider(widget.treatmentId));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(l10n.prescriptionDeleted)),
                                      );
                                    }
                                  }
                                }
                              },
                            ),
                            onTap: () =>
                                _showPrescriptionDialog(context,
                                    existing: p),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (e, _) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child:
                        Text(l10n.errorLoadingPrescriptions(e.toString())),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(title: Text(l10n.treatment)),
        body: const LoadingWidget(),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(l10n.treatment)),
        body: ErrorDisplayWidget(message: e.toString()),
      ),
    );
  }

  String _prescriptionSummary(AppLocalizations l10n, Prescription p) {
    final dosageText = p.displayDosage();
    if (p.scheduleType == 'times_per_day') {
      final times = p.scheduleTimes ?? [];
      final labels = times.map((t) {
        final h = int.tryParse(t.split(':').first) ?? 0;
        if (h < 11) return l10n.morning;
        if (h < 15) return l10n.noon;
        if (h < 20) return l10n.evening;
        return l10n.beforeSleep;
      }).join(', ');
      return '$dosageText · $labels · ${p.durationDays} ${l10n.durationDaysLabel}';
    }
    return l10n.prescriptionSummary(
        dosageText, p.intervalHours, p.durationDays);
  }

  /// Build unit dropdown items for dosage selector.
  List<DropdownMenuItem<String>> _unitItems(
      BuildContext context, AppLocalizations l10n) {
    return [
      DropdownMenuItem(value: 'pieces', child: Text(l10n.unitPieces)),
      DropdownMenuItem(value: 'pills', child: Text(l10n.unitPills)),
      DropdownMenuItem(value: 'tablets', child: Text(l10n.unitTablets)),
      DropdownMenuItem(value: 'capsules', child: Text(l10n.unitCapsules)),
      DropdownMenuItem(value: 'ml', child: Text(l10n.unitMl)),
      DropdownMenuItem(value: 'drops', child: Text(l10n.unitDrops)),
      DropdownMenuItem(value: 'bustine', child: Text(l10n.unitBustine)),
      DropdownMenuItem(value: 'ampoules', child: Text(l10n.unitAmpoules)),
      DropdownMenuItem(value: 'suppositories', child: Text(l10n.unitSuppositories)),
      DropdownMenuItem(value: 'patches', child: Text(l10n.unitPatches)),
    ];
  }

  /// Compare two nullable string lists for equality.
  static bool _listEquals(List<String>? a, List<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Shows add or edit prescription as a full-screen bottom sheet.
  void _showPrescriptionDialog(BuildContext context,
      {Prescription? existing}) {
    final l10n = AppLocalizations.of(context);
    final isEdit = existing != null;

    // Dosage: split into amount + unit
    final dosageAmountController = TextEditingController(
      text: existing?.dosageAmount != null
          ? (existing!.dosageAmount! % 1 == 0
              ? existing.dosageAmount!.toInt().toString()
              : existing.dosageAmount.toString())
          : '',
    );
    // Legacy free-text dosage (used when no amount set)
    final dosageFreeController =
        TextEditingController(text: existing?.dosage ?? '');
    final intervalController =
        TextEditingController(text: (existing?.intervalHours ?? 8).toString());
    final durationController =
        TextEditingController(text: (existing?.durationDays ?? 7).toString());
    final notesController =
        TextEditingController(text: existing?.notes ?? '');
    String? selectedMedicationId = existing?.medicationId;
    String? dosageUnitOverride = existing?.dosageUnit;

    // Schedule type state
    String scheduleType = existing?.scheduleType ?? 'fixed_interval';
    List<String> selectedTimes = List.of(existing?.scheduleTimes ?? []);
    bool autoDiminish = existing?.autoDiminish ?? false;

    final medications = ref.read(medicationListProvider).value ?? [];

    /// Format expiry date for display in dropdown.
    String medLabel(m) {
      final expiry = m.expiryDate;
      final unit = m.quantityUnit;
      final parts = <String>[m.name];
      if (expiry != null) {
        parts.add(
            '(${expiry.day.toString().padLeft(2, '0')}.${expiry.month.toString().padLeft(2, '0')}.${expiry.year})');
      }
      if (unit != null && unit.isNotEmpty) {
        parts.add('· ${m.quantity} $unit');
      }
      return parts.join(' ');
    }

    /// Get medication unit for currently selected medication.
    String? selectedMedUnit() {
      if (selectedMedicationId == null) return null;
      return medications
          .where((m) => m.id == selectedMedicationId)
          .firstOrNull
          ?.quantityUnit;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final medUnit = selectedMedUnit();

           return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (ctx, scrollCtrl) => Column(
                children: [
                  // Handle bar
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Title
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            isEdit
                                ? l10n.editPrescription
                                : l10n.addPrescription,
                            style: Theme.of(ctx)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        // ── Medication ──
                        Text(l10n.medicationLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).colorScheme.primary,
                            )),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: selectedMedicationId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 14),
                            hintText: l10n.selectMedication,
                          ),
                          items: medications
                              .where((m) => !m.isArchived)
                              .map((m) {
                            return DropdownMenuItem(
                              value: m.id,
                              child: Text(
                                medLabel(m),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: isEdit
                              ? null
                              : (value) {
                                  setSheetState(() {
                                    selectedMedicationId = value;
                                    // Reset unit override so it inherits from new med
                                    dosageUnitOverride = null;
                                  });
                                },
                        ),
                        const SizedBox(height: 20),

                        // ── Dosage ──
                        Text(l10n.dosageLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).colorScheme.primary,
                            )),
                        const SizedBox(height: 8),
                        // If medication has a unit → show numeric amount + unit row
                        // Otherwise show free-text field
                        if (medUnit != null) ...[
                          Row(
                            children: [
                              // Amount field (numeric: 0.5, 1, 2, etc.)
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: dosageAmountController,
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    labelText: l10n.dosageLabel,
                                    prefixIcon: const Icon(Icons.medication),
                                  ),
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Unit — override or use medication's unit
                              Expanded(
                                flex: 3,
                                child: DropdownButtonFormField<String>(
                                  initialValue: dosageUnitOverride ?? medUnit,
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    labelText: l10n.quantityUnit,
                                  ),
                                  items: _unitItems(ctx, l10n),
                                  onChanged: (v) => setSheetState(
                                      () => dosageUnitOverride = v),
                                ),
                              ),
                            ],
                          ),
                        ] else ...[
                          // Free-text dosage (e.g. "20 Tropfen", "500mg")
                          TextFormField(
                            controller: dosageFreeController,
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              hintText: l10n.dosageHint,
                              prefixIcon: const Icon(Icons.medication),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),

                      // ── Schedule ──
                      Text(l10n.scheduleType,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(ctx).colorScheme.primary,
                          )),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'fixed_interval',
                            label: Text(l10n.fixedInterval,
                                style: const TextStyle(fontSize: 12)),
                            icon: const Icon(Icons.timer, size: 16),
                          ),
                          ButtonSegment(
                            value: 'times_per_day',
                            label: Text(l10n.timesPerDay,
                                style: const TextStyle(fontSize: 12)),
                            icon: const Icon(Icons.schedule, size: 16),
                          ),
                        ],
                        selected: {scheduleType},
                        onSelectionChanged: (s) {
                          setSheetState(() => scheduleType = s.first);
                        },
                      ),
                      const SizedBox(height: 12),

                      if (scheduleType == 'fixed_interval')
                        TextFormField(
                          controller: intervalController,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: l10n.intervalHoursLabel,
                            prefixIcon: const Icon(Icons.repeat),
                          ),
                          keyboardType: TextInputType.number,
                        ),

                      if (scheduleType == 'times_per_day') ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            _TimeChip(
                              label: '${l10n.morning} (08:00)',
                              value: '08:00',
                              selected: selectedTimes.contains('08:00'),
                              onToggle: (v) {
                                setSheetState(() {
                                  if (v) {
                                    selectedTimes.add('08:00');
                                  } else {
                                    selectedTimes.remove('08:00');
                                  }
                                });
                              },
                            ),
                            _TimeChip(
                              label: '${l10n.noon} (12:00)',
                              value: '12:00',
                              selected: selectedTimes.contains('12:00'),
                              onToggle: (v) {
                                setSheetState(() {
                                  if (v) {
                                    selectedTimes.add('12:00');
                                  } else {
                                    selectedTimes.remove('12:00');
                                  }
                                });
                              },
                            ),
                            _TimeChip(
                              label: '${l10n.evening} (18:00)',
                              value: '18:00',
                              selected: selectedTimes.contains('18:00'),
                              onToggle: (v) {
                                setSheetState(() {
                                  if (v) {
                                    selectedTimes.add('18:00');
                                  } else {
                                    selectedTimes.remove('18:00');
                                  }
                                });
                              },
                            ),
                            _TimeChip(
                              label: '${l10n.beforeSleep} (22:00)',
                              value: '22:00',
                              selected: selectedTimes.contains('22:00'),
                              onToggle: (v) {
                                setSheetState(() {
                                  if (v) {
                                    selectedTimes.add('22:00');
                                  } else {
                                    selectedTimes.remove('22:00');
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),

                      // ── Duration ──
                      Text(l10n.durationDaysLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(ctx).colorScheme.primary,
                          )),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: durationController,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.date_range),
                          suffixText: l10n.durationDaysLabel,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 16),

                      // ── Auto-diminish toggle ──
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.autoDiminish),
                        subtitle: Text(l10n.autoDiminishHint,
                            style: const TextStyle(fontSize: 12)),
                        value: autoDiminish,
                        onChanged: (v) =>
                            setSheetState(() => autoDiminish = v),
                      ),
                      const SizedBox(height: 12),

                      // ── Notes ──
                      TextFormField(
                        controller: notesController,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: l10n.notes,
                          prefixIcon: const Icon(Icons.notes),
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 24),

                      // ── Save button ──
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          icon: Icon(isEdit ? Icons.save : Icons.add),
                          label: Text(isEdit ? l10n.update : l10n.add),
                          onPressed: () async {
                            if (selectedMedicationId == null) return;

                            // Build dosage fields
                            final medUnit = selectedMedUnit();
                            final double? amount =
                                double.tryParse(dosageAmountController.text.trim().replaceAll(',', '.'));
                            final String dosageText = medUnit != null
                                ? (amount != null
                                    ? '${amount % 1 == 0 ? amount.toInt() : amount} ${dosageUnitOverride ?? medUnit}'
                                    : dosageFreeController.text.trim())
                                : dosageFreeController.text.trim();

                            if (dosageText.isEmpty && amount == null) return;

                            int interval =
                                int.tryParse(intervalController.text) ?? 8;
                            if (scheduleType == 'times_per_day' &&
                                selectedTimes.isNotEmpty) {
                              interval =
                                  (24 / selectedTimes.length).round();
                            }

                            final prescription = Prescription(
                              id: existing?.id ?? const Uuid().v4(),
                              treatmentId: widget.treatmentId,
                              medicationId: selectedMedicationId!,
                              dosage: dosageText,
                              dosageAmount: amount,
                              dosageUnit: dosageUnitOverride,
                              intervalHours: interval,
                              durationDays:
                                  int.tryParse(durationController.text) ??
                                      7,
                              startTime:
                                  existing?.startTime ?? DateTime.now(),
                              isActive: true,
                              autoDiminish: autoDiminish,
                              notes: notesController.text.trim().isEmpty
                                  ? null
                                  : notesController.text.trim(),
                              scheduleType: scheduleType,
                              scheduleTimes:
                                  scheduleType == 'times_per_day'
                                      ? selectedTimes
                                      : null,
                            );

                            final repo =
                                ref.read(prescriptionRepositoryProvider);
                            bool saved = false;

                            if (isEdit) {
                              // Detect whether schedule-affecting fields changed
                              final scheduleChanged =
                                  existing.intervalHours != prescription.intervalHours ||
                                  existing.durationDays != prescription.durationDays ||
                                  existing.scheduleType != prescription.scheduleType ||
                                  existing.startTime != prescription.startTime ||
                                  _listEquals(existing.scheduleTimes, prescription.scheduleTimes) == false;

                              final result =
                                  await repo.updatePrescription(
                                      prescription);
                              await result.when(
                                success: (_) async {
                                  saved = true;
                                  // Only regenerate dose logs if schedule changed
                                  if (scheduleChanged) {
                                    try {
                                      final doseLogRepo = ref
                                          .read(doseLogRepositoryProvider);
                                      final doseResult = await doseLogRepo
                                          .regenerateDoseLogsForPrescription(
                                              prescription.id);
                                      doseResult.when(
                                        success: (doses) {
                                          debugPrint('✅ Regenerated ${doses.length} doses for edited prescription');
                                        },
                                        failure: (msg) {
                                          debugPrint('⚠ Failed to regenerate doses: $msg');
                                        },
                                      );
                                    } catch (e) {
                                      debugPrint('⚠ Dose regeneration error: $e');
                                    }
                                  }
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              l10n.prescriptionUpdated)),
                                    );
                                  }
                                },
                                failure: (msg) async {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      SnackBar(
                                          content: Text('Error: $msg')),
                                    );
                                  }
                                },
                              );
                            } else {
                              final result =
                                  await repo.addPrescription(
                                      prescription);
                              await result.when(
                                success: (p) async {
                                  saved = true;
                                  // Generate dose logs for new prescription
                                  try {
                                    final doseLogRepo = ref
                                        .read(doseLogRepositoryProvider);
                                    final doseResult = await doseLogRepo
                                        .generateDoseLogsForPrescription(
                                            p.id);
                                    doseResult.when(
                                      success: (doses) {
                                        debugPrint('✅ Generated ${doses.length} doses for new prescription');
                                      },
                                      failure: (msg) {
                                        debugPrint('⚠ Failed to generate doses: $msg');
                                      },
                                    );
                                  } catch (e) {
                                    debugPrint('⚠ Dose generation error: $e');
                                  }

                                  // Schedule reminders (non-blocking)
                                  try {
                                    final medName = medications
                                            .where((m) =>
                                                m.id ==
                                                selectedMedicationId)
                                            .firstOrNull
                                            ?.name ??
                                        l10n.medication;

                                    ReminderService.instance
                                        .scheduleRepeatingReminders(
                                      prescriptionId: p.id,
                                      medicationName: medName,
                                      dosage: p.dosage,
                                      startTime: p.startTime,
                                      intervalHours: p.intervalHours,
                                      durationDays: p.durationDays,
                                    );
                                  } catch (_) {}
                                },
                                failure: (msg) async {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      SnackBar(
                                          content: Text('Error: $msg')),
                                    );
                                  }
                                },
                              );
                            }

                            if (ctx.mounted) Navigator.pop(ctx);

                            if (saved) {
                              // Invalidate immediately — no delay needed
                              ref.invalidate(
                                  prescriptionsByTreatmentProvider(
                                      widget.treatmentId));
                              ref.invalidate(todaysDoseLogsProvider);
                              ref.invalidate(activePrescriptionsProvider);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        },
      ),
    );
  }
}

class _TimeChip extends StatelessWidget {
  const _TimeChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onToggle,
  });

  final String label;
  final String value;
  final bool selected;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: onToggle,
      visualDensity: VisualDensity.compact,
    );
  }
}
