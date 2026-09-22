/// One prescription on the treatment detail screen: the swipe-to-delete
/// card, its menu, the intake line and the "Log dose" button an as-needed
/// prescription gets.
///
/// Lifted out of `treatment_detail_screen.dart`, where it was 370 lines
/// inside a `map` inside a `build`, four closures deep. Everything it shows
/// it is given; everything it changes it does through the providers, as the
/// screen did.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';

class PrescriptionCard extends ConsumerWidget {
  const PrescriptionCard({
    super.key,
    required this.prescription,
    required this.treatmentId,
    required this.treatmentActive,
    required this.unit,
    required this.intake,
    required this.logging,
    required this.onLogDose,
  });

  final Prescription prescription;
  final String treatmentId;

  /// An ended treatment takes no more doses, so its as-needed prescriptions
  /// lose the "Log dose" button.
  final bool treatmentActive;

  /// The medication's quantity unit: a prescription that uses it stores no
  /// unit of its own.
  final String? unit;

  /// The intake line, already formatted; null while the doses load or when
  /// they cannot be read, where a "Not taken" would not be known to be true.
  final String? intake;

  /// This prescription's "Log dose" is saving: a second tap would record a
  /// second intake and take the stock down twice.
  final bool logging;

  final VoidCallback onLogDose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final p = prescription;
    return Dismissible(
      key: ValueKey(p.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: context.colors.error,
        child: Icon(Icons.delete, color: context.colors.onError),
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
                  style: TextStyle(color: context.colors.error),
                ),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) async {
        final repo = ref.read(prescriptionRepositoryProvider);
        await repo.deletePrescription(p.id);
        ref.invalidate(prescriptionsByTreatmentProvider(treatmentId));
        ref.invalidateDoseData();
        unawaited(ref.read(reminderSchedulerProvider).reconcile());
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.prescriptionDeleted)));
        }
      },
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
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
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_prescriptionSummary(l10n, p, unit)),
                  if (!p.isActive)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.surfaceContainerHighest,
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
                          style: TextStyle(color: context.medora.success),
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
                        style: TextStyle(color: context.colors.error),
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
                      treatmentId: treatmentId,
                      existing: p,
                    );
                  } else if (action == 'deactivate') {
                    final repo = ref.read(prescriptionRepositoryProvider);
                    await repo.deactivatePrescription(p.id);
                    ref.invalidate(
                      prescriptionsByTreatmentProvider(treatmentId),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.prescriptionDeactivated)),
                      );
                    }
                  } else if (action == 'reactivate') {
                    final repo = ref.read(prescriptionRepositoryProvider);
                    await repo.reactivatePrescription(p.id);
                    ref.invalidate(
                      prescriptionsByTreatmentProvider(treatmentId),
                    );
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
                            child: Text(
                              l10n.delete,
                              style: TextStyle(color: context.colors.error),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      final repo = ref.read(prescriptionRepositoryProvider);
                      await repo.deletePrescription(p.id);
                      ref.invalidate(
                        prescriptionsByTreatmentProvider(treatmentId),
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
                    }
                  }
                },
              ),
              onTap: () => showPrescriptionSheet(
                context,
                ref,
                treatmentId: treatmentId,
                existing: p,
              ),
            ),
            // What was taken, on its own row under the
            // tile: the subtitle leaves 144 dp at 360 dp and
            // 1.6x, and even in line with the title (216 dp)
            // "14 von 15 eingenommen" would wrap.
            if (intake != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
                child: Text(
                  intake!,
                  key: Key('intake_${p.id}'),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            // Nothing is scheduled, so there is nothing to
            // tick off: each intake is logged here. Below
            // the tile, not in its subtitle, which is too
            // narrow at 360 dp to keep "Dosis eintragen"
            // on one line. An ended treatment takes no
            // more doses.
            if (p.scheduleType == 'as_needed' && p.isActive && treatmentActive)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    key: Key('logDose_${p.id}'),
                    onPressed: logging ? null : onLogDose,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: Text(l10n.logDoseNow),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _prescriptionSummary(
  AppLocalizations l10n,
  Prescription p,
  String? medicationUnit,
) {
  final dosageText = prescriptionDosageLabel(
    l10n,
    p,
    medicationUnit: medicationUnit,
  );
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
  return l10n.prescriptionSummary(dosageText, p.intervalHours, p.durationDays);
}
