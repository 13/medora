/// Medora - Shared Widgets
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';

/// Badge showing medication expiry status.
class ExpiryBadge extends StatelessWidget {
  const ExpiryBadge({super.key, required this.expiryDate});

  final DateTime? expiryDate;

  @override
  Widget build(BuildContext context) {
    if (expiryDate == null) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final daysUntilExpiry = expiryDate!.difference(now).inDays;

    Color color;
    String label;

    if (daysUntilExpiry < 0) {
      color = AppTheme.expiredColor;
      label = l10n.expired;
    } else if (daysUntilExpiry <= 30) {
      color = AppTheme.expiringSoonColor;
      label = l10n.expiresInDaysShort(daysUntilExpiry);
    } else {
      color = AppTheme.inStockColor;
      label = l10n.valid;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
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
  });

  final int quantity;
  final int minimumStock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isLow = quantity <= minimumStock;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isLow ? Icons.warning_rounded : Icons.check_circle_rounded,
          size: 16,
          color: isLow ? AppTheme.lowStockColor : AppTheme.inStockColor,
        ),
        const SizedBox(width: 4),
        Text(
          l10n.quantityLeft(quantity),
          style: TextStyle(
            color: isLow ? AppTheme.lowStockColor : AppTheme.inStockColor,
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
    Color color;
    IconData icon;
    String label;

    switch (status) {
      case DoseStatus.taken:
        color = AppTheme.doseTakenColor;
        icon = Icons.check_circle;
        label = l10n.taken;
      case DoseStatus.skipped:
        color = AppTheme.doseSkippedColor;
        icon = Icons.skip_next;
        label = l10n.skipped;
      case DoseStatus.missed:
        color = AppTheme.doseMissedColor;
        icon = Icons.cancel;
        label = l10n.missed;
      case DoseStatus.pending:
        color = AppTheme.dosePendingColor;
        icon = Icons.schedule;
        label = l10n.pending;
    }

    return Chip(
      avatar: Icon(icon, color: color, size: 18),
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.1),
      labelStyle: TextStyle(color: color, fontSize: 12),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[500],
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
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
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
