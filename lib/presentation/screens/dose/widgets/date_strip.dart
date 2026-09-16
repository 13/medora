/// Medora - Dose schedule: the seven-day date strip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/dose_providers.dart';

class DateStrip extends StatelessWidget {
  const DateStrip({
    super.key,
    required this.today,
    required this.selected,
    required this.now,
  });

  final DateTime today;
  final DateTime selected;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          for (var i = -3; i <= 3; i++)
            Expanded(
              child: DayChip(
                day: dayKey(DateTime(today.year, today.month, today.day + i)),
                selected:
                    selected ==
                    dayKey(DateTime(today.year, today.month, today.day + i)),
                now: now,
              ),
            ),
        ],
      ),
    );
  }
}

class DayChip extends ConsumerWidget {
  const DayChip({
    super.key,
    required this.day,
    required this.selected,
    required this.now,
  });

  final DateTime day;
  final bool selected;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doses = ref.watch(dosesForDayProvider(day)).value;
    final pending =
        doses?.where((d) => d.status == DoseStatus.pending) ??
        const Iterable.empty();
    final hasPending = pending.isNotEmpty;
    final hasOverduePending = pending.any((d) => d.scheduledTime.isBefore(now));

    Color? dotColor;
    if (hasOverduePending) {
      dotColor = context.medora.danger;
    } else if (hasPending) {
      dotColor = context.medora.neutral;
    }

    final background = selected ? context.colors.primary : Colors.transparent;
    final foreground = selected
        ? context.colors.onPrimary
        : context.colors.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => ref.read(selectedDoseDayProvider.notifier).set(day),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                day.weekdayShort,
                style: TextStyle(fontSize: 11, color: foreground),
              ),
              const SizedBox(height: 2),
              Text(
                '${day.day}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: foreground,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 6,
                width: 6,
                child: dotColor == null
                    ? null
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
