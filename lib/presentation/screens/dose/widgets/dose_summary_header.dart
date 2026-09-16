/// Medora - Dose schedule: the day's summary card.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

class DoseSummaryHeader extends StatelessWidget {
  const DoseSummaryHeader({required this.doses, super.key});

  final List<DoseLog> doses;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    int total = 0, taken = 0, skipped = 0, missed = 0, pending = 0;
    for (final dose in doses) {
      total++;
      switch (dose.status) {
        case DoseStatus.taken:
          taken++;
        case DoseStatus.skipped:
          skipped++;
        case DoseStatus.missed:
          missed++;
        case DoseStatus.pending:
          pending++;
      }
    }

    final isSmall = MediaQuery.sizeOf(context).width < 360;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(isSmall ? 10 : 16),
        child: Column(
          children: [
            Text(
              l10n.dosesProgress(taken, total, pending),
              style: TextStyle(
                color: context.colors.onSurfaceVariant,
                fontSize: isSmall ? 12 : 14,
              ),
            ),
            const SizedBox(height: 12),
            StatChip(
              count: taken,
              label: l10n.taken,
              color: context.medora.success,
              compact: isSmall,
              large: true,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: isSmall ? 12 : 20,
              runSpacing: 8,
              children: [
                StatChip(
                  count: pending,
                  label: l10n.pending,
                  color: context.medora.neutral,
                  compact: isSmall,
                ),
                StatChip(
                  count: skipped,
                  label: l10n.skipped,
                  color: context.medora.warning,
                  compact: isSmall,
                ),
                StatChip(
                  count: missed,
                  label: l10n.missed,
                  color: context.medora.danger,
                  compact: isSmall,
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: total > 0 ? (taken + skipped + missed) / total : 0,
                backgroundColor: context.colors.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  context.colors.primary,
                ),
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
class StatChip extends StatelessWidget {
  const StatChip({
    super.key,
    required this.count,
    required this.label,
    required this.color,
    this.compact = false,
    this.large = false,
  });

  final int count;
  final String label;
  final Color color;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (large) {
      return Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
                fontSize: 14,
              ),
            ),
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
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: context.colors.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
