/// Medora - Dose Schedule Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:go_router/go_router.dart';

class DoseScheduleScreen extends ConsumerWidget {
  const DoseScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dosesAsync = ref.watch(todaysDoseLogsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.todaysDosesTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.doseHistory,
            onPressed: () => context.push(AppRoutes.doseHistory),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(todaysDoseLogsProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: dosesAsync.when(
        data: (doses) {
          if (doses.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.check_circle_outline,
              title: l10n.noDosesScheduledToday,
              subtitle: l10n.createTreatmentForDoses,
            );
          }

          final pending =
              doses.where((d) => d.status == DoseStatus.pending).toList();
          final completed =
              doses.where((d) => d.status != DoseStatus.pending).toList();

          return RefreshIndicator(
            onRefresh: () async {
              ref.read(todaysDoseLogsProvider.notifier).refresh();
            },
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _DoseSummaryHeader(doses: doses),
                const SizedBox(height: 16),

                if (pending.isNotEmpty) ...[
                  Text(
                    l10n.upcoming,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...pending.map((dose) => _DoseCard(dose: dose, ref: ref)),
                  const SizedBox(height: 16),
                ],

                if (completed.isNotEmpty) ...[
                  Text(
                    l10n.completed,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...completed.map((dose) => _DoseCard(dose: dose, ref: ref)),
                ],
              ],
            ),
          );
        },
        loading: () => LoadingWidget(message: l10n.loadingDoses),
        error: (error, _) => ErrorDisplayWidget(
          message: error.toString(),
          onRetry: () =>
              ref.read(todaysDoseLogsProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

// ── Summary Header (responsive) ────────────────────────────────

class _DoseSummaryHeader extends StatelessWidget {
  const _DoseSummaryHeader({required this.doses});

  final List<DoseLog> doses;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final total = doses.length;
    final taken = doses.where((d) => d.status == DoseStatus.taken).length;
    final skipped = doses.where((d) => d.status == DoseStatus.skipped).length;
    final missed = doses.where((d) => d.status == DoseStatus.missed).length;
    final pending = doses.where((d) => d.status == DoseStatus.pending).length;
    final isSmall = MediaQuery.sizeOf(context).width < 360;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(isSmall ? 10 : 16),
        child: Column(
          children: [
            Text(
              DateTime.now().formatted,
              style: TextStyle(color: Colors.grey[600], fontSize: isSmall ? 12 : 14),
            ),
            const SizedBox(height: 10),
            // Wrap for small screens instead of fixed Row
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: isSmall ? 12 : 20,
              runSpacing: 8,
              children: [
                _StatChip(count: taken, label: l10n.taken, color: AppTheme.doseTakenColor, compact: isSmall),
                _StatChip(count: pending, label: l10n.pending, color: AppTheme.dosePendingColor, compact: isSmall),
                _StatChip(count: skipped, label: l10n.skipped, color: AppTheme.doseSkippedColor, compact: isSmall),
                _StatChip(count: missed, label: l10n.missed, color: AppTheme.doseMissedColor, compact: isSmall),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: total > 0 ? (taken + skipped + missed) / total : 0,
                backgroundColor: Colors.grey[200],
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact stat chip that works on small screens.
class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.count,
    required this.label,
    required this.color,
    this.compact = false,
  });

  final int count;
  final String label;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      // Horizontal chip layout for narrow screens
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$count', style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }
}

// ── Dose Card (clickable + responsive) ─────────────────────────

class _DoseCard extends StatelessWidget {
  const _DoseCard({required this.dose, required this.ref});

  final DoseLog dose;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isPending = dose.status == DoseStatus.pending;
    final isSmall = MediaQuery.sizeOf(context).width < 360;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
        child: Padding(
          padding: EdgeInsets.all(isSmall ? 8 : 12),
          child: Row(
            children: [
              // Time column
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
                    if (dose.isOverdue)
                      Text(
                        l10n.overdue,
                        style: TextStyle(
                          color: AppTheme.doseMissedColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: isSmall ? 8 : 16),

              // Medication info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dose.medicationName ?? l10n.unknownMedication,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: isSmall ? 13 : 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dose.displayDosage != null)
                      Text(
                        dose.displayDosage!,
                        style: TextStyle(color: Colors.grey[600], fontSize: isSmall ? 11 : 13),
                      ),
                    if (dose.prescriptionNotes != null && dose.prescriptionNotes!.isNotEmpty)
                      Text(
                        dose.prescriptionNotes!,
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    // Treatment and patient info
                    if (dose.treatmentName != null || dose.patientTags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            if (dose.treatmentName != null) ...[
                              Icon(Icons.medical_services, size: 11, color: Colors.grey[500]),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  dose.treatmentName!,
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            if (dose.treatmentName != null && dose.patientTags.isNotEmpty)
                              Text(' · ', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                            if (dose.patientTags.isNotEmpty) ...[
                              Icon(Icons.person, size: 11, color: Colors.grey[500]),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  dose.patientTags.join(', '),
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              // Actions or status
              if (isPending) ...[
                if (!isSmall)
                  IconButton(
                    onPressed: () => ref
                        .read(todaysDoseLogsProvider.notifier)
                        .markSkipped(dose.id),
                    icon: const Icon(Icons.skip_next, size: 20),
                    tooltip: l10n.skip,
                    color: AppTheme.doseSkippedColor,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                FilledButton(
                  onPressed: () => ref
                      .read(todaysDoseLogsProvider.notifier)
                      .markTaken(dose.id),
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: isSmall ? 10 : 16),
                    minimumSize: Size(isSmall ? 48 : 64, 34),
                  ),
                  child: Text(l10n.take, style: TextStyle(fontSize: isSmall ? 12 : 14)),
                ),
              ] else
                DoseStatusChip(status: dose.status),
            ],
          ),
        ),
      ),
    );
  }
}
