/// A year as twelve small calendars, three across and four down, with the
/// days of sick leave filled in.
///
/// The shape is the one `~/repo/dontdrink` draws a year in
/// (`lib/ui/yearly/widgets/year_months_grid.dart`): a year read as a pattern
/// rather than a list — the bad month, the week it turned around — in the
/// layout people actually read dates in.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

class YearMonthsGrid extends StatelessWidget {
  const YearMonthsGrid({
    super.key,
    required this.year,
    required this.sickDays,
    required this.today,
    this.onDayTap,
  });

  final int year;

  /// The days of [year] signed off, at midnight (see `sick_leave_stats.dart`,
  /// which hands this straight over).
  final Set<DateTime> sickDays;

  /// "Today", from `nowProvider` at the caller. Days after it are drawn as
  /// future and cannot be tapped.
  final DateTime today;

  final void Function(DateTime date)? onDayTap;

  /// The key of [date]'s cell, so a test can find one day among 365.
  static ValueKey<String> cellKey(DateTime date) => ValueKey(
    'day_${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}',
  );

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final todayDate = DateTime(today.year, today.month, today.day);

    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        const gap = 10.0;
        final monthWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Column(
          children: [
            for (var row = 0; row < 4; row++) ...[
              if (row > 0) const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: monthWidth,
                      child: _MiniMonth(
                        month: DateTime(year, row * columns + col + 1),
                        sickDays: sickDays,
                        today: todayDate,
                        locale: locale,
                        onDayTap: onDayTap,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MiniMonth extends StatelessWidget {
  const _MiniMonth({
    required this.month,
    required this.sickDays,
    required this.today,
    required this.locale,
    required this.onDayTap,
  });

  final DateTime month;
  final Set<DateTime> sickDays;
  final DateTime today;
  final String locale;
  final void Function(DateTime date)? onDayTap;

  /// Day 0 of the next month is the last day of this one.
  int get _daysInMonth => DateTime(month.year, month.month + 1, 0).day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysInMonth = _daysInMonth;
    // Dart's weekday runs Mon=1..Sun=7 and this grid is Monday-first, so the
    // blanks before the 1st are simply weekday - 1.
    final leadingBlanks = DateTime(month.year, month.month).weekday - 1;

    // Narrow weekday letters from the locale, rotated to start on Monday:
    // intl indexes them from Sunday.
    final narrow = DateFormat.EEEE(locale).dateSymbols.NARROWWEEKDAYS;
    final weekdayLetters = [for (var i = 1; i <= 7; i++) narrow[i % 7]];

    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = constraints.maxWidth / 7;
        // A cell is about 15 logical pixels wide on a phone. Below 7 the day
        // numbers stop being readable; above 11 they stop fitting.
        final fontSize = (cell * 0.58).clamp(7.0, 11.0);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat.MMMM(locale).format(month),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              // The month name is the one label here that a large text scale
              // can blow up; the grid below it is sized from the cell.
              textScaler: TextScaler.noScaling,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                for (final letter in weekdayLetters)
                  SizedBox(
                    width: cell,
                    child: Text(
                      letter,
                      textAlign: TextAlign.center,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        fontSize: fontSize * 0.85,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            for (var week = 0; week * 7 < leadingBlanks + daysInMonth; week++)
              Row(
                children: [
                  for (var slot = 0; slot < 7; slot++)
                    _cellAt(
                      week,
                      slot,
                      leadingBlanks,
                      daysInMonth,
                      cell,
                      fontSize,
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _cellAt(
    int week,
    int slot,
    int leadingBlanks,
    int daysInMonth,
    double size,
    double fontSize,
  ) {
    final day = week * 7 + slot - leadingBlanks + 1;
    if (day < 1 || day > daysInMonth) {
      return SizedBox(width: size, height: size);
    }
    final date = DateTime(month.year, month.month, day);
    return YearDayCell(
      key: YearMonthsGrid.cellKey(date),
      date: date,
      size: size,
      fontSize: fontSize,
      isSick: sickDays.contains(date),
      isToday: date == today,
      isFuture: date.isAfter(today),
      locale: locale,
      onTap: onDayTap,
    );
  }
}

/// One day of the year grid.
///
/// Public, and carrying its own state as fields, so a test can ask a single
/// day what it thinks it is instead of reading pixels.
class YearDayCell extends StatelessWidget {
  const YearDayCell({
    super.key,
    required this.date,
    required this.size,
    required this.fontSize,
    required this.isSick,
    required this.isToday,
    required this.isFuture,
    required this.locale,
    this.onTap,
  });

  final DateTime date;
  final double size;
  final double fontSize;
  final bool isSick;
  final bool isToday;
  final bool isFuture;
  final String locale;
  final void Function(DateTime date)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    // Sick days take the warning container, the same colour the sick-leave
    // badge uses, so the two read as one thing across the app.
    final background = isSick
        ? context.medora.warningContainer
        : theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: isFuture ? 0.3 : 1,
          );
    final foreground = isSick
        ? context.medora.onWarningContainer
        : theme.colorScheme.onSurfaceVariant.withValues(
            alpha: isFuture ? 0.4 : 1,
          );

    final tappable = !isFuture && onTap != null;
    return Semantics(
      button: tappable,
      label:
          '${DateFormat.yMMMMd(locale).format(date)}, '
          '${isSick ? l10n.statsDaySick : l10n.statsDayWell}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: tappable ? () => onTap!(date) : null,
        child: Padding(
          padding: const EdgeInsets.all(0.5),
          child: Container(
            width: size - 1,
            height: size - 1,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(3),
              border: isToday
                  ? Border.all(color: theme.colorScheme.primary)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '${date.day}',
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: fontSize,
                height: 1,
                color: foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
