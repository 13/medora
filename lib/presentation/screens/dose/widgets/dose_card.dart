/// Medora - Dose schedule: one dose row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class DoseCard extends ConsumerWidget {
  const DoseCard({
    super.key,
    required this.dose,
    required this.overdue,
    required this.busy,
    required this.onTake,
    required this.onSkip,
  });

  final DoseLog dose;
  final bool overdue;
  final bool busy;
  final VoidCallback onTake;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isPending = dose.status == DoseStatus.pending;
    final isSmall = MediaQuery.sizeOf(context).width < 360;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: overdue
          ? context.medora.dangerContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
        child: Padding(
          padding: EdgeInsets.all(isSmall ? 8 : 12),
          child: Row(
            children: [
              SizedBox(
                width: isSmall ? 48 : 56,
                child: Column(
                  children: [
                    Text(
                      dose.scheduledTime.timeFormatted,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isSmall ? 13 : 16,
                      ),
                    ),
                    if (overdue)
                      Text(
                        l10n.overdue,
                        style: TextStyle(
                          color: context.medora.danger,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: isSmall ? 8 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dose.medicationName ?? l10n.unknownMedication,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: isSmall ? 13 : 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dosageLabel(l10n, dose) != null)
                      Text(
                        dosageLabel(l10n, dose)!,
                        style: TextStyle(
                          color: context.colors.onSurfaceVariant,
                          fontSize: isSmall ? 11 : 13,
                        ),
                      ),
                    if (dose.prescriptionNotes?.isNotEmpty == true)
                      Text(
                        dose.prescriptionNotes!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    if (dose.treatmentName != null ||
                        dose.patientTags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (dose.treatmentName != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.medical_services,
                                    size: 11,
                                    color: context.colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    dose.treatmentName!,
                                    style: TextStyle(
                                      color: context.colors.onSurfaceVariant,
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                            ...dose.patientTags.map(
                              (t) => TagChip(
                                label: t,
                                fontSize: 10,
                                icon: Icons.person,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (isPending)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isSmall)
                      IconButton(
                        onPressed: busy ? null : onSkip,
                        icon: const Icon(Icons.skip_next, size: 20),
                        tooltip: l10n.skip,
                        color: context.medora.warning,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                    FilledButton(
                      onPressed: busy ? null : onTake,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: isSmall ? 10 : 16,
                        ),
                        minimumSize: Size(isSmall ? 48 : 64, 34),
                      ),
                      child: Text(
                        l10n.take,
                        style: TextStyle(fontSize: isSmall ? 12 : 14),
                      ),
                    ),
                  ],
                )
              else
                DoseStatusChip(
                  status: dose.status,
                  suffix: dose.status == DoseStatus.taken
                      ? dose.takenTime?.timeFormatted
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
