/// Medora - Treatment Detail Screen
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/screens/treatment/end_treatment_dialog.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class TreatmentDetailScreen extends ConsumerStatefulWidget {
  const TreatmentDetailScreen({super.key, required this.treatmentId});

  final String treatmentId;

  @override
  ConsumerState<TreatmentDetailScreen> createState() =>
      _TreatmentDetailScreenState();
}

class _TreatmentDetailScreenState extends ConsumerState<TreatmentDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final treatmentsAsync = ref.watch(treatmentListProvider);
    final prescriptionsAsync = ref.watch(
      prescriptionsByTreatmentProvider(widget.treatmentId),
    );
    final treatment = treatmentsAsync.value
        ?.where((t) => t.id == widget.treatmentId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(treatment?.name ?? l10n.treatment),
        actions: treatment == null
            ? null
            : [
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
                        await confirmAndEndTreatment(context, ref, treatment);
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
                                child: Text(
                                  l10n.delete,
                                  style: TextStyle(color: context.colors.error),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true && context.mounted) {
                          // Fire and forget: pop immediately, the list
                          // provider refreshes itself when the write lands.
                          unawaited(
                            ref
                                .read(treatmentListProvider.notifier)
                                .deleteTreatment(treatment.id),
                          );
                          if (context.mounted) context.pop();
                        }
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (treatment.isActive)
                      PopupMenuItem(
                        value: 'end',
                        child: ListTile(
                          leading: Icon(
                            Icons.stop_circle,
                            color: context.medora.warning,
                          ),
                          title: Text(l10n.endTreatment),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(
                          Icons.delete,
                          color: context.colors.error,
                        ),
                        title: Text(l10n.deleteTreatment),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
      ),
      body: AsyncValueView<List<Treatment>>(
        value: treatmentsAsync,
        data: (treatments) {
          final treatment = treatments
              .where((t) => t.id == widget.treatmentId)
              .firstOrNull;
          if (treatment == null) {
            return EmptyStateWidget(
              icon: Icons.error_outline,
              title: l10n.treatmentNotFound,
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status card
              Card(
                color: treatment.isActive
                    ? context.medora.successContainer
                    : context.colors.surfaceContainerHighest,
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
                                ? context.medora.onSuccessContainer
                                : context.colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            treatment.isActive ? l10n.active : l10n.ended,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: treatment.isActive
                                  ? context.medora.onSuccessContainer
                                  : context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (treatment.patientTags.isNotEmpty) ...[
                        Text(
                          l10n.treatmentPatientTags,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.patientTags.map((t) {
                            return TagChip(
                              label: t,
                              icon: Icons.person,
                              fontSize: 12,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (treatment.symptomTags.isNotEmpty) ...[
                        Text(
                          l10n.treatmentSymptomTags,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.symptomTags.map((s) {
                            return TagChip(label: s, fontSize: 12);
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
                                Text(
                                  l10n.startDate,
                                  style: TextStyle(
                                    color: context.colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(treatment.startDate.formatted),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.endDate,
                                  style: TextStyle(
                                    color: context.colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  treatment.endDate.formattedOr(l10n.ongoing),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (treatment.notes != null &&
                          treatment.notes!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.notes,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(treatment.notes!),
                      ],
                    ],
                  ),
                ),
              ),
              if (_SickLeaveBlock.hasContent(treatment)) ...[
                const SizedBox(height: 12),
                _SickLeaveBlock(treatment: treatment, now: now),
              ],
              const SizedBox(height: 20),

              // Prescriptions section. A Wrap, not a Row: in German at a
              // 1.6x text scale "Verschreibungen" and "Hinzufügen" overflow
              // 328 dp by 52 dp, so the button moves to its own line.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    l10n.prescriptions,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (treatment.isActive)
                    TextButton.icon(
                      onPressed: () => showPrescriptionSheet(
                        context,
                        ref,
                        treatmentId: widget.treatmentId,
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.add),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              AsyncValueView<List<Prescription>>(
                value: prescriptionsAsync,
                compact: true,
                onRetry: () async => ref.invalidate(
                  prescriptionsByTreatmentProvider(widget.treatmentId),
                ),
                emptyWhen: (prescriptions) => prescriptions.isEmpty,
                empty: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.medication_outlined,
                          size: 48,
                          color: context.colors.outline,
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.noPrescriptionsYet),
                        if (treatment.isActive) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => showPrescriptionSheet(
                              context,
                              ref,
                              treatmentId: widget.treatmentId,
                            ),
                            child: Text(l10n.addPrescription),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                data: (prescriptions) {
                  return Column(
                    children: prescriptions.map((p) {
                      return Dismissible(
                        key: ValueKey(p.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: context.colors.error,
                          child: Icon(
                            Icons.delete,
                            color: context.colors.onError,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
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
                                  child: Text(
                                    l10n.delete,
                                    style: TextStyle(
                                      color: context.colors.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                        onDismissed: (_) async {
                          final repo = ref.read(prescriptionRepositoryProvider);
                          await repo.deletePrescription(p.id);
                          ref.invalidate(
                            prescriptionsByTreatmentProvider(
                              widget.treatmentId,
                            ),
                          );
                          ref.invalidateDoseData();
                          unawaited(
                            ref.read(reminderSchedulerProvider).reconcile(),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l10n.prescriptionDeleted)),
                            );
                          }
                        },
                        child: Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: context.colors.primary,
                              child: Icon(
                                Icons.medication,
                                color: context.colors.onPrimary,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              p.medicationName ?? l10n.unknownMedication,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_prescriptionSummary(l10n, p)),
                                // Nothing is scheduled, so there is nothing to
                                // tick off: each intake is logged here.
                                if (p.scheduleType == 'as_needed' && p.isActive)
                                  Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: TextButton.icon(
                                      key: Key('logDose_${p.id}'),
                                      onPressed: () => _logAsNeededDose(p),
                                      icon: const Icon(
                                        Icons.add_circle_outline,
                                        size: 18,
                                      ),
                                      label: Text(l10n.logDoseNow),
                                    ),
                                  ),
                                if (!p.isActive)
                                  Container(
                                    margin: const EdgeInsets.only(top: 4),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context
                                          .colors
                                          .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      l10n.done,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: context.colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                if (p.notes != null && p.notes!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      p.notes!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: context.colors.onSurfaceVariant,
                                      ),
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
                                      leading: const Icon(
                                        Icons.pause_circle_outline,
                                        size: 20,
                                      ),
                                      title: Text(l10n.deactivatePrescription),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                if (!p.isActive)
                                  PopupMenuItem(
                                    value: 'reactivate',
                                    child: ListTile(
                                      leading: Icon(
                                        Icons.play_circle_outline,
                                        size: 20,
                                        color: context.medora.success,
                                      ),
                                      title: Text(
                                        l10n.reactivatePrescription,
                                        style: TextStyle(
                                          color: context.medora.success,
                                        ),
                                      ),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.delete,
                                      size: 20,
                                      color: context.colors.error,
                                    ),
                                    title: Text(
                                      l10n.delete,
                                      style: TextStyle(
                                        color: context.colors.error,
                                      ),
                                    ),
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  await showPrescriptionSheet(
                                    context,
                                    ref,
                                    treatmentId: widget.treatmentId,
                                    existing: p,
                                  );
                                } else if (action == 'deactivate') {
                                  final repo = ref.read(
                                    prescriptionRepositoryProvider,
                                  );
                                  await repo.deactivatePrescription(p.id);
                                  ref.invalidate(
                                    prescriptionsByTreatmentProvider(
                                      widget.treatmentId,
                                    ),
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.prescriptionDeactivated,
                                        ),
                                      ),
                                    );
                                  }
                                } else if (action == 'reactivate') {
                                  final repo = ref.read(
                                    prescriptionRepositoryProvider,
                                  );
                                  await repo.reactivatePrescription(p.id);
                                  ref.invalidate(
                                    prescriptionsByTreatmentProvider(
                                      widget.treatmentId,
                                    ),
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.prescriptionReactivated,
                                        ),
                                      ),
                                    );
                                  }
                                } else if (action == 'delete') {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text(l10n.deletePrescription),
                                      content: Text(
                                        l10n.deletePrescriptionConfirm,
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
                                          child: Text(
                                            l10n.delete,
                                            style: TextStyle(
                                              color: context.colors.error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    final repo = ref.read(
                                      prescriptionRepositoryProvider,
                                    );
                                    await repo.deletePrescription(p.id);
                                    ref.invalidate(
                                      prescriptionsByTreatmentProvider(
                                        widget.treatmentId,
                                      ),
                                    );
                                    ref.invalidateDoseData();
                                    unawaited(
                                      ref
                                          .read(reminderSchedulerProvider)
                                          .reconcile(),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.prescriptionDeleted,
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                }
                              },
                            ),
                            onTap: () => showPrescriptionSheet(
                              context,
                              ref,
                              treatmentId: widget.treatmentId,
                              existing: p,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _logAsNeededDose(Prescription p) async {
    final l10n = AppLocalizations.of(context);
    final actions = ref.read(doseActionsProvider);
    final id = await actions.logAsNeededDose(p.id);
    if (!mounted || id == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.doseLogged),
        // A tap by mistake has already moved the stock; this takes both back.
        action: SnackBarAction(
          label: l10n.undo,
          onPressed: () => unawaited(actions.undoTake(id)),
        ),
      ),
    );
  }

  String _prescriptionSummary(AppLocalizations l10n, Prescription p) {
    final dosageText = prescriptionDosageLabel(l10n, p);
    if (p.scheduleType == 'as_needed') {
      return '$dosageText · ${l10n.scheduleAsNeeded}';
    }
    if (p.scheduleType == 'times_per_day') {
      final times = p.scheduleTimes ?? [];
      final labels = times
          .map((t) {
            final h = int.tryParse(t.split(':').first) ?? 0;
            if (h < 11) return l10n.morning;
            if (h < 15) return l10n.noon;
            if (h < 20) return l10n.evening;
            return l10n.beforeSleep;
          })
          .join(', ');
      return '$dosageText · $labels · ${p.durationDays} ${l10n.durationDaysLabel}';
    }
    return l10n.prescriptionSummary(
      dosageText,
      p.intervalHours,
      p.durationDays,
    );
  }
}

/// The Krankenstand card: the leave's range, its length, the certificate
/// number and the doctor, each row only when it has a value. It shows when
/// any of the four fields is set, since the form saves each one on its own
/// (a certificate number often arrives before the dates are known).
///
/// The rows are [_SickLeaveRow]s, not the shared `DetailRow`: that one puts
/// "label: value" on one line with only the value flexible, so at 360 dp and
/// a 1.6x text scale the value was left 23 dp ("1234567890" one digit per
/// line) and Italian "In malattia fino al: " overflowed the card by 52 dp.
class _SickLeaveBlock extends StatelessWidget {
  const _SickLeaveBlock({required this.treatment, required this.now});

  final Treatment treatment;
  final DateTime now;

  static bool hasContent(Treatment t) => _hasLeaveData(t) || t.doctor != null;

  /// Anything that belongs to the leave itself, as opposed to the doctor.
  static bool _hasLeaveData(Treatment t) =>
      t.sickLeaveFrom != null ||
      t.sickLeaveTo != null ||
      t.sickLeaveRef != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final from = treatment.sickLeaveFrom;
    final to = treatment.sickLeaveTo;
    // Null for a leave that has not started or ends before it starts: the
    // row is left out rather than showing a count that is not true.
    final days = treatment.sickLeaveDaysAt(now);
    return Card(
      key: const Key('sickLeaveBlock'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A doctor alone is not a sick leave, so the card does not claim
            // one with the heading.
            if (_hasLeaveData(treatment)) ...[
              Row(
                children: [
                  Icon(Icons.work_off, color: context.colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sickLeave,
                      style: context.text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (from != null)
              _SickLeaveRow(
                icon: Icons.event_busy,
                label: l10n.sickLeaveFrom,
                value: from.formatted,
              ),
            // An open leave reads "Ongoing"; an end date with no start (only
            // from a synced or restored row) still shows its date.
            if (from != null || to != null)
              _SickLeaveRow(
                icon: Icons.event_available,
                label: l10n.sickLeaveTo,
                value: to.formattedOr(l10n.ongoing),
              ),
            if (days != null)
              _SickLeaveRow(
                icon: Icons.today,
                label: l10n.sickLeaveDuration,
                value: l10n.sickLeaveDays(days),
              ),
            if (treatment.sickLeaveRef != null)
              _SickLeaveRow(
                icon: Icons.confirmation_number,
                label: l10n.sickLeaveRef,
                value: treatment.sickLeaveRef!,
              ),
            if (treatment.doctor != null)
              _SickLeaveRow(
                icon: Icons.medical_services,
                label: l10n.doctorLabel,
                value: treatment.doctor!,
              ),
          ],
        ),
      ),
    );
  }
}

/// An icon beside a small label with its value underneath. Stacked rather
/// than side by side, so a long label never squeezes the value.
class _SickLeaveRow extends StatelessWidget {
  const _SickLeaveRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: context.colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
