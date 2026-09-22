/// Medora - A year of sick leave, counted and drawn.
///
/// The numbers come from `sick_leave_stats.dart`, which deduplicates the
/// days: two illnesses in one week are the days they actually were, not the
/// sum of two ranges. This screen only arranges them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/sick_leave_stats.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/year_months_grid.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  /// Null until the treatments are read: the year to open on is the current
  /// one, which needs the clock, and reading it in `initState` would miss a
  /// `nowProvider` override in a test.
  int? _year;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(treatmentListProvider);
    final now = ref.watch(nowProvider)();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.statistics)),
      body: SafeArea(
        child: AsyncValueView<List<Treatment>>(
          value: treatmentsAsync,
          onRetry: () async =>
              ref.read(treatmentListProvider.notifier).refresh(),
          data: (treatments) {
            final year = _year ??= now.year;
            final firstYear = firstSickLeaveYear(treatments) ?? now.year;
            final stats = SickLeaveStats.of(year, treatments, now: now);
            final previous = SickLeaveStats.of(year - 1, treatments, now: now);

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _YearStepper(
                  year: year,
                  min: firstYear,
                  max: now.year,
                  onChange: (value) => setState(() => _year = value),
                ),
                const SizedBox(height: 16),
                _Headline(stats: stats, previous: previous),
                const SizedBox(height: 16),
                YearMonthsGrid(
                  year: year,
                  sickDays: stats.days,
                  today: now,
                  onDayTap: (date) => _showDay(date, treatments, now),
                ),
                if (stats.isEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    firstSickLeaveYear(treatments) == null
                        ? l10n.statsNoLeaveEver
                        : l10n.statsNoLeaveThisYear(year),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else ...[
                  const SizedBox(height: 24),
                  _MonthBars(stats: stats),
                  const SizedBox(height: 24),
                  _ByIllness(stats: stats),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Which illnesses covered [date]. A day can belong to more than one, which
  /// is the whole reason the totals are deduplicated.
  void _showDay(DateTime date, List<Treatment> treatments, DateTime now) {
    final l10n = AppLocalizations.of(context);
    final day = DateTime(date.year, date.month, date.day);
    final names = [
      for (final treatment in treatments)
        if (sickDaysIn(day.year, [treatment], now: now).contains(day))
          treatment.name,
    ];
    if (names.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.statsDayDetail(
            DateFormat.yMMMMd(
              Localizations.localeOf(context).toString(),
            ).format(day),
            names.join(', '),
          ),
        ),
      ),
    );
  }
}

class _YearStepper extends StatelessWidget {
  const _YearStepper({
    required this.year,
    required this.min,
    required this.max,
    required this.onChange,
  });

  final int year;
  final int min;
  final int max;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.filledTonal(
          key: const Key('stats_prev_year'),
          onPressed: year > min ? () => onChange(year - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            '$year',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton.filledTonal(
          key: const Key('stats_next_year'),
          onPressed: year < max ? () => onChange(year + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.stats, required this.previous});

  final SickLeaveStats stats;
  final SickLeaveStats previous;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final difference = stats.totalDays - previous.totalDays;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.statsSickDaysTitle, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(
              l10n.statsTotalDays(stats.totalDays),
              key: const Key('stats_total'),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            // Wrap, not Row: "Durchschnitt" and "Episoden" together overrun
            // 360 dp at a large text scale.
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(l10n.statsEpisodes(stats.episodes)),
                Text(
                  '${l10n.statsLongest}: '
                  '${l10n.statsDaysShort(stats.longestEpisodeDays)}',
                ),
                Text(
                  '${l10n.statsAverage}: '
                  '${l10n.statsDaysShort(stats.averageEpisodeDays.round())}',
                ),
              ],
            ),
            if (!previous.isEmpty || !stats.isEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${l10n.statsVsLastYear(previous.year)}: '
                '${difference == 0
                    ? l10n.statsSameAsLastYear
                    : difference > 0
                    ? l10n.statsMoreThanLastYear(difference)
                    : l10n.statsFewerThanLastYear(-difference)}',
                key: const Key('stats_vs_last_year'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.stats});

  final SickLeaveStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final busiest = stats.byMonth.reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l10n.statsByMonth),
        const SizedBox(height: 8),
        // The bar takes whatever height is left after the two labels,
        // as a fraction of the worst month: computing a pixel height here
        // instead overflowed the row by 4 px as soon as a label grew.
        SizedBox(
          height: 110,
          child: Row(
            children: [
              for (var month = 0; month < 12; month++)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        stats.byMonth[month] > 0
                            ? '${stats.byMonth[month]}'
                            : '',
                        textScaler: TextScaler.noScaling,
                        style: theme.textTheme.labelSmall,
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            // A month with no days still gets a sliver, so
                            // the row reads as twelve months rather than as
                            // a gap where some of them should be.
                            heightFactor: busiest == 0
                                ? 0.04
                                : (stats.byMonth[month] / busiest).clamp(
                                    0.04,
                                    1.0,
                                  ),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: stats.byMonth[month] == 0
                                    ? theme.colorScheme.surfaceContainerHighest
                                    : context.medora.warning,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        DateFormat.MMMM(locale).dateSymbols.NARROWMONTHS[month],
                        textScaler: TextScaler.noScaling,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ByIllness extends StatelessWidget {
  const _ByIllness({required this.stats});

  final SickLeaveStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final worst = stats.byTreatment.first.days;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l10n.statsByIllness),
        const SizedBox(height: 8),
        for (final entry in stats.byTreatment)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: worst == 0 ? 0 : entry.days / worst,
                      minHeight: 8,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(
                        context.medora.warning,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.statsDaysShort(entry.days),
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        if (stats.byTreatment.length > 1) ...[
          const SizedBox(height: 8),
          Text(
            l10n.statsByIllnessNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// A heading over a block of the page, styled like the ones on the treatment
/// detail screen. Home's own `_SectionHeader` carries a "see all" action
/// that nothing here needs.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );
}
