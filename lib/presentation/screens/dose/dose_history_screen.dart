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
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// Provider to load dose logs for a date range.
/// Depends on [doseDataVersionProvider] so it auto-refreshes
/// when doses are modified (taken/skipped/missed).
final doseHistoryProvider =
    FutureProvider.family<List<DoseLog>, ({DateTime start, DateTime end})>(
  (ref, range) async {
    // Watch the version counter to trigger refetch when doses change
    ref.watch(doseDataVersionProvider);
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
            child: historyAsync.when(
              data: (doses) {
                if (doses.isEmpty) {
                  return EmptyStateWidget(
                    icon: Icons.history,
                    title: l10n.noDoseHistory,
                  );
                }

                // Group by date (using ISO date string for correct sorting)
                final grouped = <String, List<DoseLog>>{};
                for (final d in doses) {
                  final key = '${d.scheduledTime.year}-'
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
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        ...entry.value.map((dose) => _DoseHistoryTile(dose: dose, ref: ref)),
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
        statusColor = AppTheme.successColor;
        statusIcon = Icons.check_circle;
        statusLabel = l10n.taken;
      case DoseStatus.skipped:
        statusColor = Colors.orange;
        statusIcon = Icons.skip_next;
        statusLabel = l10n.skip;
      case DoseStatus.missed:
        statusColor = Colors.red;
        statusIcon = Icons.cancel;
        statusLabel = l10n.missed;
      case DoseStatus.pending:
        statusColor = Colors.grey;
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
      onTap: () => showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
      leading: Icon(statusIcon, color: statusColor, size: 28),
      title: Text(
        dose.medicationName ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dose.displayDosage != null && dose.displayDosage!.isNotEmpty)
            Text(
              dose.displayDosage!,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
                        Icon(Icons.medical_services, size: 11, color: Colors.grey[500]),
                        const SizedBox(width: 3),
                        Text(
                          dose.treatmentName!,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ...dose.patientTags.map((t) => TagChip(label: t, fontSize: 10, icon: Icons.person)),
                ],
              ),
            ),
          if (dose.prescriptionNotes != null && dose.prescriptionNotes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                dose.prescriptionNotes!,
                style: TextStyle(fontSize: 11, color: Colors.grey[500], fontStyle: FontStyle.italic),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(scheduledTime, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            statusLabel,
            style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w500),
          ),
          if (takenTimeStr != null)
            Text(
              '@ $takenTimeStr',
              style: TextStyle(color: Colors.grey[500], fontSize: 10),
            ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
