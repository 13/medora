/// Medora - Shared Widgets
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';

/// Badge showing medication expiry status.
class ExpiryBadge extends StatelessWidget {
  const ExpiryBadge({super.key, required this.expiryDate, required this.now});

  final DateTime? expiryDate;

  /// "Now" injected by the nearest consumer (`ref.watch(nowProvider)()`).
  /// The badge never reads the wall clock itself, so its rendering is
  /// deterministic under test and cannot drift between rebuilds.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final expiry = expiryDate;
    if (expiry == null) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final daysUntilExpiry = calendarDaysBetween(now, expiry);
    final medora = context.medora;

    final (bg, fg, label) = daysUntilExpiry < 0
        ? (medora.dangerContainer, medora.onDangerContainer, l10n.expired)
        // The same window `expiringSoonProvider` uses to decide what reaches
        // the dashboard at all. Two copies of the number would let the card
        // draw a green "Valid" pill on a row it had just flagged.
        : daysUntilExpiry <= AppConstants.expiryWarningDays
        ? (
            medora.warningContainer,
            medora.onWarningContainer,
            l10n.expiresInDaysShort(daysUntilExpiry),
          )
        : (medora.successContainer, medora.onSuccessContainer, l10n.valid);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
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
        Icon(icon, size: 16, color: color),
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
  const DoseStatusChip({super.key, required this.status, this.suffix});

  final DoseStatus status;

  /// When non-null, appended to the label as `'$label · $suffix'` (e.g. a
  /// taken time), keeping it inside the same [Text] as the status word.
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final medora = context.medora;

    final (bg, fg, icon, label) = switch (status) {
      DoseStatus.taken => (
        medora.successContainer,
        medora.onSuccessContainer,
        Icons.check_circle,
        l10n.taken,
      ),
      DoseStatus.skipped => (
        medora.warningContainer,
        medora.onWarningContainer,
        Icons.skip_next,
        l10n.skipped,
      ),
      DoseStatus.missed => (
        medora.dangerContainer,
        medora.onDangerContainer,
        Icons.cancel,
        l10n.missed,
      ),
      DoseStatus.pending => (
        medora.neutralContainer,
        medora.onNeutralContainer,
        Icons.schedule,
        l10n.pending,
      ),
    };

    return Chip(
      avatar: Icon(icon, color: fg, size: 18),
      label: Text(suffix == null ? label : '$label · $suffix'),
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
    final color = HSLColor.fromColor(
      label.toColor,
    ).withLightness(isDark ? 0.75 : 0.35).toColor();
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
  final now = ref.read(nowProvider)();
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

  showModalBottomSheet<void>(
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
                  child: Icon(
                    Icons.medication,
                    color: context.colors.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dose.medicationName ?? l10n.unknownMedication,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (dosageLabel(l10n, dose) != null)
                        Text(
                          dosageLabel(l10n, dose)!,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                DoseStatusChip(status: dose.status),
              ],
            ),
            const Divider(height: 24),

            // Details
            DetailRow(
              icon: Icons.calendar_today,
              label: l10n.date,
              value: dateLabel,
            ),
            DetailRow(
              icon: Icons.schedule,
              label: l10n.selectTimes,
              value: dose.scheduledTime.timeFormatted,
            ),
            if (dose.treatmentName != null)
              DetailRow(
                icon: Icons.medical_services,
                label: l10n.treatment,
                value: dose.treatmentName!,
              ),
            if (dose.patientTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.person,
                      size: 18,
                      color: context.colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${l10n.patientTagsField}: ',
                      style: TextStyle(
                        color: context.colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: dose.patientTags
                            .map(
                              (t) => TagChip(
                                label: t,
                                icon: Icons.person,
                                fontSize: 12,
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            if (dose.prescriptionNotes != null &&
                dose.prescriptionNotes!.isNotEmpty)
              DetailRow(
                icon: Icons.sticky_note_2,
                label: l10n.notes,
                value: dose.prescriptionNotes!,
              ),
            if (dose.takenTime != null)
              DetailRow(
                icon: Icons.check_circle,
                label: l10n.taken,
                value: dose.takenTime!.timeFormatted,
              ),
            if (dose.notes != null && dose.notes!.isNotEmpty)
              DetailRow(
                icon: Icons.notes,
                label: l10n.notes,
                value: dose.notes!,
              ),

            const SizedBox(height: 16),

            // Action buttons
            _DoseSheetActions(
              dose: dose,
              actions: ref.read(doseActionsProvider),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Take / skip / undo buttons of the dose detail sheet.
///
/// Stateful so the buttons can be disabled while the write is in flight,
/// and so the result of the action is actually awaited — a failed write
/// used to close the sheet silently.
class _DoseSheetActions extends StatefulWidget {
  const _DoseSheetActions({required this.dose, required this.actions});

  final DoseLog dose;

  /// Read from the provider container before the sheet was built, so it
  /// stays valid even though this sheet outlives nothing in particular.
  final DoseActions actions;

  @override
  State<_DoseSheetActions> createState() => _DoseSheetActionsState();
}

class _DoseSheetActionsState extends State<_DoseSheetActions> {
  bool _busy = false;

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    // Captured before the await: the sheet is popped below, so `context`
    // is gone by the time the SnackBar has to be shown.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final l10n = AppLocalizations.of(context);
    bool ok;
    try {
      ok = await action();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    navigator.pop();
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dose = widget.dose;
    if (dose.status == DoseStatus.pending) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.actions.skip(dose.id)),
              icon: const Icon(Icons.skip_next),
              label: Text(l10n.skip),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.actions.take(dose.id)),
              icon: const Icon(Icons.check),
              label: Text(l10n.take),
            ),
          ),
        ],
      );
    }
    if (dose.status == DoseStatus.taken) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() => widget.actions.undoTake(dose.id)),
          icon: const Icon(Icons.undo),
          label: Text(l10n.undoTaken),
          style: OutlinedButton.styleFrom(
            foregroundColor: context.colors.error,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
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
    final labelStyle = TextStyle(
      color: context.colors.onSurfaceVariant,
      fontSize: 13,
    );
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
              ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
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
  const ErrorDisplayWidget({super.key, required this.message, this.onRetry});

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
