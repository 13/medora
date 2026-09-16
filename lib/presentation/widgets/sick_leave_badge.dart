/// Medora - The sick-leave (Krankenstand) badge of a treatment.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// "Sick leave · Day 3" while a leave is open, "Sick leave · 7 days" once it
/// is closed, and plain "Sick leave" when the leave has no valid day count
/// (it has not started yet, or it ends before it starts).
///
/// Unlike a [TagChip], whose colour is hashed from its label, the colour is
/// fixed: the label changes every day, and the badge must not.
///
/// In a narrow slot the label wraps at its spaces onto a second line
/// ("Krankenstand ·" / "Tag 31" at 360 dp and a 1.6x text scale) instead of
/// being cut; the ellipsis after two lines is only a backstop.
class SickLeaveBadge extends StatelessWidget {
  const SickLeaveBadge({
    super.key,
    required this.treatment,
    required this.now,
    this.fontSize = 11,
  });

  final Treatment treatment;

  /// "Now" injected by the nearest consumer (`ref.watch(nowProvider)()`).
  final DateTime now;
  final double fontSize;

  /// The badge's text for [treatment] at [now].
  static String labelFor(
    Treatment treatment,
    DateTime now,
    AppLocalizations l10n,
  ) {
    final days = treatment.sickLeaveDaysAt(now);
    if (days == null) return l10n.sickLeave;
    final count = treatment.isSickLeaveOpen
        ? l10n.sickLeaveDay(days)
        : l10n.sickLeaveDays(days);
    return '${l10n.sickLeave} · $count';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final foreground = context.colors.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.work_off, size: fontSize + 1, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              labelFor(treatment, now, l10n),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
