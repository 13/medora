/// Medora - Dose History Screen
///
/// Shows past dose logs grouped by date.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Provider to load dose logs for a date range.
final doseHistoryProvider =
    FutureProvider.family<List<DoseLog>, ({DateTime start, DateTime end})>(
  (ref, range) async {
    final repo = ref.watch(doseLogRepositoryProvider);
    final result = await repo.getDoseLogsByDateRange(range.start, range.end);
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  },
);

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
    final now = DateTime.now();
    _endDate = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    _startDate = _endDate.subtract(const Duration(days: 7));
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
            child: historyAsync.when(
              data: (doses) {
                if (doses.isEmpty) {
                  return EmptyStateWidget(
                    icon: Icons.history,
                    title: l10n.noDoseHistory,
                  );
                }

                // Group by date
                final grouped = <String, List<DoseLog>>{};
                for (final d in doses) {
                  final key = d.scheduledTime.shortFormatted;
                  (grouped[key] ??= []).add(d);
                }

                final days = grouped.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key)); // nearest first

                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: days.length,
                  itemBuilder: (context, index) {
                    final entry = days[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            entry.key,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...entry.value.map((dose) => _DoseHistoryTile(dose: dose)),
                      ],
                    );
                  },
                );
              },
              loading: () => const LoadingWidget(),
              error: (e, _) => ErrorDisplayWidget(
                message: e.toString(),
                onRetry: () => ref.invalidate(doseHistoryProvider(range)),
              ),
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
      lastDate: DateTime.now().add(const Duration(days: 1)),
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
  const _DoseHistoryTile({required this.dose});

  final DoseLog dose;

  @override
  Widget build(BuildContext context) {
    final time =
        '${dose.scheduledTime.hour.toString().padLeft(2, '0')}:${dose.scheduledTime.minute.toString().padLeft(2, '0')}';

    Color statusColor;
    IconData statusIcon;
    switch (dose.status) {
      case DoseStatus.taken:
        statusColor = AppTheme.successColor;
        statusIcon = Icons.check_circle;
      case DoseStatus.skipped:
        statusColor = Colors.orange;
        statusIcon = Icons.skip_next;
      case DoseStatus.missed:
        statusColor = Colors.red;
        statusIcon = Icons.cancel;
      case DoseStatus.pending:
        statusColor = Colors.grey;
        statusIcon = Icons.schedule;
    }

    return ListTile(
      leading: Icon(statusIcon, color: statusColor),
      title: Text(
        dose.medicationName ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(dose.displayDosage ?? ''),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(time, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            dose.status.name,
            style: TextStyle(color: statusColor, fontSize: 12),
          ),
        ],
      ),
      dense: true,
    );
  }
}


