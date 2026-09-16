/// Medora - Dose schedule: the time-of-day grouping and its header.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

class TimeGroup {
  const TimeGroup(this.label, this.doses);

  final String label;
  final List<DoseLog> doses;

  /// Only doses actually taken — the header reads "N of M taken", so
  /// skipped and missed doses must not be counted here.
  int get taken => doses.where((d) => d.status == DoseStatus.taken).length;
}

List<TimeGroup> timeOfDayGroups(List<DoseLog> doses, AppLocalizations l10n) {
  final morning = <DoseLog>[];
  final afternoon = <DoseLog>[];
  final evening = <DoseLog>[];
  final night = <DoseLog>[];

  for (final dose in doses) {
    final hour = dose.scheduledTime.hour;
    if (hour < 12) {
      morning.add(dose);
    } else if (hour < 17) {
      afternoon.add(dose);
    } else if (hour < 21) {
      evening.add(dose);
    } else {
      night.add(dose);
    }
  }

  for (final group in [morning, afternoon, evening, night]) {
    group.sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
  }

  return [
    if (morning.isNotEmpty) TimeGroup(l10n.morning, morning),
    if (afternoon.isNotEmpty) TimeGroup(l10n.afternoon, afternoon),
    if (evening.isNotEmpty) TimeGroup(l10n.evening, evening),
    if (night.isNotEmpty) TimeGroup(l10n.night, night),
  ];
}

class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.label,
    required this.taken,
    required this.total,
  });

  final String label;
  final int taken;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Text(
          '$taken/$total',
          style: TextStyle(
            color: context.colors.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
