/// Medora - Dose History Screen
///
/// Shows past dose logs grouped by date.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Provider to load dose logs for a date range.
/// Depends on [doseDataVersionProvider] so it auto-refreshes
/// when doses are modified (taken/skipped/missed).
final doseHistoryProvider =
    FutureProvider.family<List<DoseLog>, ({DateTime start, DateTime end})>((
      ref,
      range,
    ) async {
      // Watch the version counter to trigger refetch when doses change
      ref.watch(doseDataVersionProvider);
      final repo = ref.watch(doseLogRepositoryProvider);
      final result = await repo.getDoseLogsByDateRange(range.start, range.end);
      return result.when(
        success: (data) => data,
        failure: (msg) => throw Exception(msg),
      );
    });

class DoseHistoryScreen extends ConsumerStatefulWidget {
  const DoseHistoryScreen({super.key});

  @override
  ConsumerState<DoseHistoryScreen> createState() => _DoseHistoryScreenState();
}

class _DoseHistoryScreenState extends ConsumerState<DoseHistoryScreen> {
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    final now = ref.read(nowProvider)();
    _endDate = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    _startDate = _endDate.subtract(const Duration(days: 7));

    // Invalidate any cached history data so we get fresh results
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invalidateCurrentRange();
    });
  }

  void _invalidateCurrentRange() {
    ref.invalidate(doseHistoryProvider((start: _startDate, end: _endDate)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final range = (start: _startDate, end: _endDate);
    final historyAsync = ref.watch(doseHistoryProvider(range));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.doseHistory),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _invalidateCurrentRange,
          ),
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: _pickDateRange,
          ),
        ],
      ),
      body: Column(
        children: [
          // Date range indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    setState(() {
                      _endDate = _startDate;
                      _startDate = _startDate.subtract(const Duration(days: 7));
                    });
                  },
                ),
                Text(
                  '${_startDate.shortFormatted} – ${_endDate.subtract(const Duration(days: 1)).shortFormatted}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () {
                    setState(() {
                      _startDate = _endDate;
                      _endDate = _endDate.add(const Duration(days: 7));
                    });
                  },
                ),
              ],
            ),
          ),
          // Dose list
          Expanded(
            child: AsyncValueView<List<DoseLog>>(
              value: historyAsync,
              onRetry: () async => _invalidateCurrentRange(),
              emptyWhen: (doses) => doses.isEmpty,
              empty: EmptyStateWidget(
                icon: Icons.history,
                title: l10n.noDoseHistory,
              ),
              data: (doses) {
                // Group by date (using ISO date string for correct sorting)
                final grouped = <String, List<DoseLog>>{};
                for (final d in doses) {
                  final key =
                      '${d.scheduledTime.year}-'
                      '${d.scheduledTime.month.toString().padLeft(2, '0')}-'
                      '${d.scheduledTime.day.toString().padLeft(2, '0')}';
                  (grouped[key] ??= []).add(d);
                }

                final days = grouped.entries.toList()
                  ..sort((a, b) => b.key.compareTo(a.key)); // newest first

                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: days.length,
                  itemBuilder: (context, index) {
                    final entry = days[index];
                    // Parse date from key for display
                    final displayDate = DateTime.tryParse(entry.key);
                    final dateLabel = displayDate?.formatted ?? entry.key;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            dateLabel,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...entry.value.map(
                          (dose) => _DoseHistoryTile(dose: dose, ref: ref),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: ref.read(nowProvider)().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: _startDate,
        end: _endDate.subtract(const Duration(days: 1)),
      ),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end.add(const Duration(days: 1));
      });
    }
  }
}

class _DoseHistoryTile extends StatelessWidget {
  const _DoseHistoryTile({required this.dose, required this.ref});

  final DoseLog dose;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheduledTime =
        '${dose.scheduledTime.hour.toString().padLeft(2, '0')}:${dose.scheduledTime.minute.toString().padLeft(2, '0')}';

    Color statusColor;
    IconData statusIcon;
    String statusLabel;
    switch (dose.status) {
      case DoseStatus.taken:
        statusColor = context.medora.success;
        statusIcon = Icons.check_circle;
        statusLabel = l10n.taken;
      case DoseStatus.skipped:
        statusColor = context.medora.warning;
        statusIcon = Icons.skip_next;
        statusLabel = l10n.skip;
      case DoseStatus.missed:
        statusColor = context.medora.danger;
        statusIcon = Icons.cancel;
        statusLabel = l10n.missed;
      case DoseStatus.pending:
        statusColor = context.medora.neutral;
        statusIcon = Icons.schedule;
        statusLabel = l10n.pending;
    }

    // Taken time display
    String? takenTimeStr;
    if (dose.status == DoseStatus.taken && dose.takenTime != null) {
      takenTimeStr =
          '${dose.takenTime!.hour.toString().padLeft(2, '0')}:${dose.takenTime!.minute.toString().padLeft(2, '0')}';
    }

    return ListTile(
      onTap: () =>
          showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
      leading: Icon(statusIcon, color: statusColor, size: 28),
      title: Text(
        dose.medicationName ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dosageLabel(l10n, dose)?.isNotEmpty ?? false)
            Text(
              dosageLabel(l10n, dose)!,
              style: TextStyle(
                fontSize: 12,
                color: context.colors.onSurfaceVariant,
              ),
            ),
          // Treatment and patient info with chips
          if (dose.treatmentName != null || dose.patientTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (dose.treatmentName != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.medical_services,
                          size: 11,
                          color: context.colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          dose.treatmentName!,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ...dose.patientTags.map(
                    (t) => TagChip(label: t, fontSize: 10, icon: Icons.person),
                  ),
                ],
              ),
            ),
          if (dose.prescriptionNotes != null &&
              dose.prescriptionNotes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                dose.prescriptionNotes!,
                style: TextStyle(
                  fontSize: 11,
                  color: context.colors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      // Cap the column, do not let it take the row. A ListTile hands its
      // trailing slot loose constraints - the whole 320 dp of content width
      // at 360 dp - so this column claimed its natural width and the title
      // was left whatever remained (at 360 dp the title's box is always
      // 260 dp minus this column). In German at 1.6x the status word is
      // "Ueberspringen" and the column took 121.2 dp, so "Tachipirina 1000"
      // got 138.8 dp for a word needing 140.2 and was broken mid-word.
      // Nothing overflowed sideways and nothing left the viewport, so
      // takeException stayed silent and no earlier test saw it.
      //
      // The slot is also only 56 dp tall, and a taken dose stacks three
      // lines in it: at 1.6x that column overflowed the slot by 19 dp, the
      // same way the Home Low Stock row's trailing column did. One guard
      // settles both - BoxFit.scaleDown fits the column to the slot in
      // whichever direction it does not fit, and only ever shrinks.
      //
      // The cap is bounded on both sides and both bounds are measured, not
      // guessed. It must stay above 0.3225: German's widest column is
      // 103.2 dp of the 320 dp slot at 1.3x, the top of Android's font-size
      // slider, and a cap below that would narrow a column that fits, which
      // is shrinking text the user asked to be bigger for no reason. It must stay below 0.3744, which is
      // the 119.8 dp that leaves "Tachipirina 1000" the 140.2 dp it needs
      // at 1.6x. 0.35 sits between them with about 9 dp either side. German
      // is the only locale this ever bites: Italian and English want
      // 76.5 dp and 72.4 dp at that same 1.6x.
      //
      // The time and the status repeat what the row already says - the
      // leading icon carries the same status in colour - so this column is
      // what gives way, and the medication name keeps its row.
      trailing: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.35),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  scheduledTime,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (takenTimeStr != null)
                  Text(
                    '@ $takenTimeStr',
                    style: TextStyle(
                      color: context.colors.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      isThreeLine: true,
    );
  }
}
