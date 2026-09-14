/// Medora - Shared Widgets
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/dose_providers.dart';

/// Badge showing medication expiry status.
class ExpiryBadge extends StatelessWidget {
  const ExpiryBadge({super.key, required this.expiryDate});

  final DateTime? expiryDate;

  // Cache computed values as static to avoid recalculation
  static DateTime? _lastNowCache;
  static DateTime? _lastNow;

  static DateTime _getCachedNow() {
    final now = DateTime.now();
    // Cache for 1 minute to avoid excessive DateTime.now() calls
    if (_lastNowCache == null || now.difference(_lastNowCache!).inSeconds > 60) {
      _lastNowCache = now;
      _lastNow = DateTime(now.year, now.month, now.day);
    }
    return _lastNow!;
  }

  @override
  Widget build(BuildContext context) {
    if (expiryDate == null) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final now = _getCachedNow();
    final daysUntilExpiry = expiryDate!.difference(now).inDays;
    final medora = context.medora;

    final (bg, fg, label) = daysUntilExpiry < 0
        ? (medora.dangerContainer, medora.onDangerContainer, l10n.expired)
        : daysUntilExpiry <= 30
            ? (medora.warningContainer, medora.onWarningContainer, l10n.expiresInDaysShort(daysUntilExpiry))
            : (medora.successContainer, medora.onSuccessContainer, l10n.valid);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Indicator for medication stock level.
class StockIndicator extends StatelessWidget {
  const StockIndicator({
    super.key,
    required this.quantity,
    required this.minimumStock,
    this.isExpired = false,
  });

  final int quantity;
  final int minimumStock;
  final bool isExpired;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isLow = quantity <= minimumStock;
    final medora = context.medora;

    final (color, icon) = isExpired
        ? (medora.expired, Icons.warning_rounded)
        : isLow
            ? (medora.lowStock, Icons.warning_rounded)
            : (medora.inStock, Icons.check_circle_rounded);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(
          l10n.quantityLeft(quantity),
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Chip displaying dose status.
class DoseStatusChip extends StatelessWidget {
  const DoseStatusChip({super.key, required this.status});

  final DoseStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final medora = context.medora;

    final (bg, fg, icon, label) = switch (status) {
      DoseStatus.taken => (medora.successContainer, medora.onSuccessContainer, Icons.check_circle, l10n.taken),
      DoseStatus.skipped => (medora.warningContainer, medora.onWarningContainer, Icons.skip_next, l10n.skipped),
      DoseStatus.missed => (medora.dangerContainer, medora.onDangerContainer, Icons.cancel, l10n.missed),
      DoseStatus.pending => (medora.neutralContainer, medora.onNeutralContainer, Icons.schedule, l10n.pending),
    };

    return Chip(
      avatar: Icon(icon, color: fg, size: 18),
      label: Text(label),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 12),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// A chip for displaying tags (patient, symptom, etc.) with a unique color.
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.icon,
    this.fontSize = 11,
  });

  final String label;
  final IconData? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = HSLColor.fromColor(label.toColor).withLightness(isDark ? 0.75 : 0.35).toColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Show dose detail bottom sheet.
void showDoseDetailBottomSheet({
  required BuildContext context,
  required DoseLog dose,
  required WidgetRef ref,
}) {
  final l10n = AppLocalizations.of(context);

  // Determine date label
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final doseDate = DateTime(
    dose.scheduledTime.year,
    dose.scheduledTime.month,
    dose.scheduledTime.day,
  );

  final String dateLabel;
  if (doseDate == today) {
    dateLabel = l10n.today;
  } else if (doseDate == today.subtract(const Duration(days: 1))) {
    dateLabel = l10n.yesterday;
  } else {
    dateLabel = dose.scheduledTime.formatted;
  }

  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: context.colors.primaryContainer,
                  child: Icon(Icons.medication, color: context.colors.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dose.medicationName ?? l10n.unknownMedication,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if (dose.displayDosage != null)
                        Text(dose.displayDosage!, style: TextStyle(color: context.colors.onSurfaceVariant)),
                    ],
                  ),
                ),
                DoseStatusChip(status: dose.status),
              ],
            ),
            const Divider(height: 24),

            // Details
            DetailRow(icon: Icons.calendar_today, label: l10n.date, value: dateLabel),
            DetailRow(icon: Icons.schedule, label: l10n.selectTimes, value: dose.scheduledTime.timeFormatted),
            if (dose.treatmentName != null)
              DetailRow(icon: Icons.medical_services, label: l10n.treatment, value: dose.treatmentName!),
            if (dose.patientTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.person, size: 18, color: context.colors.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('${l10n.patientTagsField}: ', style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 13)),
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: dose.patientTags.map((t) => TagChip(label: t, icon: Icons.person, fontSize: 12)).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            if (dose.prescriptionNotes != null && dose.prescriptionNotes!.isNotEmpty)
              DetailRow(icon: Icons.sticky_note_2, label: l10n.notes, value: dose.prescriptionNotes!),
            if (dose.takenTime != null)
              DetailRow(icon: Icons.check_circle, label: l10n.taken, value: dose.takenTime!.timeFormatted),
            if (dose.notes != null && dose.notes!.isNotEmpty)
              DetailRow(icon: Icons.notes, label: l10n.notes, value: dose.notes!),

            const SizedBox(height: 16),

            // Action buttons
            if (dose.status == DoseStatus.pending)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        ref.read(todaysDoseLogsProvider.notifier).markSkipped(dose.id);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.skip_next),
                      label: Text(l10n.skip),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        ref.read(todaysDoseLogsProvider.notifier).markTaken(dose.id);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check),
                      label: Text(l10n.take),
                    ),
                  ),
                ],
              ),
            if (dose.status == DoseStatus.taken)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    ref.read(todaysDoseLogsProvider.notifier).undoTaken(dose.id);
                    Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.undo),
                  label: Text(l10n.undoTaken),
                  style: OutlinedButton.styleFrom(foregroundColor: context.colors.error),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  static const _valueStyle = TextStyle(fontSize: 13);

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(color: context.colors.onSurfaceVariant, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('$label: ', style: labelStyle),
          Expanded(child: Text(value, style: _valueStyle)),
        ],
      ),
    );
  }
}

/// Empty state placeholder widget.
class EmptyStateWidget extends StatelessWidget {
  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 24, color: context.colors.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: context.text.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: context.colors.outline),
            const SizedBox(height: 16),
            Text(
              title,
              style: context.text.titleMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: context.text.bodyMedium?.copyWith(
                      color: context.colors.outline,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Loading widget with optional message.
class LoadingWidget extends StatelessWidget {
  const LoadingWidget({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// Error widget with retry button.
class ErrorDisplayWidget extends StatelessWidget {
  const ErrorDisplayWidget({
    super.key,
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: context.colors.error),
            const SizedBox(height: 16),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
