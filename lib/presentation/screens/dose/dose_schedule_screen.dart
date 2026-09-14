/// Medora - Dose Schedule Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:go_router/go_router.dart';

class DoseScheduleScreen extends ConsumerStatefulWidget {
  const DoseScheduleScreen({super.key});

  @override
  ConsumerState<DoseScheduleScreen> createState() => _DoseScheduleScreenState();
}

class _DoseScheduleScreenState extends ConsumerState<DoseScheduleScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final Set<String> _busyIds = {};
  bool _takeAllBusy = false;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final today = dayKey(now);
    final selected = ref.watch(selectedDoseDayProvider);
    final dosesAsync = ref.watch(dosesForDayProvider(selected));

    final String title;
    if (selected == today) {
      title = l10n.today;
    } else if (selected == today.add(const Duration(days: 1))) {
      title = l10n.tomorrow;
    } else if (selected == today.subtract(const Duration(days: 1))) {
      title = l10n.yesterday;
    } else {
      title = selected.formatted;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.doseHistory,
            onPressed: () => context.push(AppRoutes.doseHistory),
          ),
        ],
      ),
      body: Column(
        children: [
          _DateStrip(today: today, selected: selected, now: now),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity < 0) {
                  ref.read(selectedDoseDayProvider.notifier).shift(1);
                } else if (velocity > 0) {
                  ref.read(selectedDoseDayProvider.notifier).shift(-1);
                }
              },
              child: AsyncValueView<List<DoseLog>>(
                value: dosesAsync,
                onRetry: () async => ref.invalidate(dosesForDayProvider(selected)),
                emptyWhen: (doses) => doses.isEmpty,
                empty: EmptyStateWidget(
                  icon: Icons.check_circle_outline,
                  title: l10n.noDosesScheduledToday,
                  subtitle: l10n.createTreatmentForDoses,
                ),
                data: (doses) => _buildDay(context, l10n, doses, now, selected),
                loading: LoadingWidget(message: l10n.loadingDoses),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDay(
    BuildContext context,
    AppLocalizations l10n,
    List<DoseLog> doses,
    DateTime now,
    DateTime selected,
  ) {
    final pendingDue = doses
        .where((d) => d.status == DoseStatus.pending && !d.scheduledTime.isAfter(now))
        .toList();
    final showTakeAllDue = pendingDue.length >= 2;
    final groups = _timeOfDayGroups(doses, l10n);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dosesForDayProvider(selected)),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _DoseSummaryHeader(doses: doses),
          const SizedBox(height: 16),
          if (showTakeAllDue) ...[
            FilledButton.tonalIcon(
              onPressed: _takeAllBusy
                  ? null
                  : () => _handleTakeAllDue(pendingDue.map((d) => d.id).toList()),
              icon: const Icon(Icons.done_all),
              label: Text(l10n.takeAllDue),
            ),
            const SizedBox(height: 16),
          ],
          for (final group in groups) ...[
            _GroupHeader(label: group.label, taken: group.taken, total: group.doses.length),
            const SizedBox(height: 6),
            ...group.doses.map(
              (dose) => _DoseCard(
                key: ValueKey(dose.id),
                dose: dose,
                overdue: dose.status == DoseStatus.pending && dose.scheduledTime.isBefore(now),
                busy: _busyIds.contains(dose.id),
                onTake: () => _handleTake(dose.id),
                onSkip: () => _handleSkip(dose.id),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Future<void> _handleTake(String id) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyIds.add(id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await ref.read(doseActionsProvider).take(id);
      if (!mounted) return;
      if (ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.doseTaken),
            action: SnackBarAction(label: l10n.undo, onPressed: () => _handleUndoTake(id)),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _handleSkip(String id) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyIds.add(id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await ref.read(doseActionsProvider).skip(id);
      if (!mounted) return;
      if (ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.doseSkipped),
            action: SnackBarAction(label: l10n.undo, onPressed: () => _handleUndoSkip(id)),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _handleUndoTake(String id) async {
    final ok = await ref.read(doseActionsProvider).undoTake(id);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).genericError)));
  }

  Future<void> _handleUndoSkip(String id) async {
    final ok = await ref.read(doseActionsProvider).undoSkip(id);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).genericError)));
  }

  Future<void> _handleTakeAllDue(List<String> ids) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _takeAllBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await ref.read(doseActionsProvider).takeAllDue(ids);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.dosesTakenCount(count)),
          action: SnackBarAction(
            label: l10n.undo,
            onPressed: () async {
              for (final id in ids) {
                await ref.read(doseActionsProvider).undoTake(id);
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => _takeAllBusy = false);
    }
  }
}

// ── Time-of-day grouping ───────────────────────────────────────

class _TimeGroup {
  const _TimeGroup(this.label, this.doses);

  final String label;
  final List<DoseLog> doses;

  int get taken => doses.where((d) => d.status != DoseStatus.pending).length;
}

List<_TimeGroup> _timeOfDayGroups(List<DoseLog> doses, AppLocalizations l10n) {
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
    if (morning.isNotEmpty) _TimeGroup(l10n.morning, morning),
    if (afternoon.isNotEmpty) _TimeGroup(l10n.afternoon, afternoon),
    if (evening.isNotEmpty) _TimeGroup(l10n.evening, evening),
    if (night.isNotEmpty) _TimeGroup(l10n.night, night),
  ];
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.taken, required this.total});

  final String label;
  final int taken;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Text('$taken/$total', style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 13)),
      ],
    );
  }
}

// ── Date strip ──────────────────────────────────────────────────

class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.today, required this.selected, required this.now});

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
              child: _DayChip(
                day: today.add(Duration(days: i)),
                selected: selected == today.add(Duration(days: i)),
                now: now,
              ),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends ConsumerWidget {
  const _DayChip({required this.day, required this.selected, required this.now});

  final DateTime day;
  final bool selected;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doses = ref.watch(dosesForDayProvider(day)).value;
    final pending = doses?.where((d) => d.status == DoseStatus.pending) ?? const Iterable.empty();
    final hasPending = pending.isNotEmpty;
    final hasOverduePending = pending.any((d) => d.scheduledTime.isBefore(now));

    Color? dotColor;
    if (hasOverduePending) {
      dotColor = context.medora.danger;
    } else if (hasPending) {
      dotColor = context.medora.neutral;
    }

    final background = selected ? context.colors.primary : Colors.transparent;
    final foreground = selected ? context.colors.onPrimary : context.colors.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => ref.read(selectedDoseDayProvider.notifier).set(day),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(day.weekdayShort, style: TextStyle(fontSize: 11, color: foreground)),
              const SizedBox(height: 2),
              Text(
                '${day.day}',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: foreground),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 6,
                width: 6,
                child: dotColor == null
                    ? null
                    : DecoratedBox(decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Summary header ────────────────────────────────────────────

class _DoseSummaryHeader extends StatelessWidget {
  const _DoseSummaryHeader({required this.doses});

  final List<DoseLog> doses;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final total = doses.length;
    final taken = doses.where((d) => d.status == DoseStatus.taken).length;
    final pending = doses.where((d) => d.status == DoseStatus.pending).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              l10n.dosesProgress(taken, total, pending),
              style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: total > 0 ? taken / total : 0,
                backgroundColor: context.colors.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(context.colors.primary),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Dose card ───────────────────────────────────────────────────

class _DoseCard extends ConsumerWidget {
  const _DoseCard({
    super.key,
    required this.dose,
    required this.overdue,
    required this.busy,
    required this.onTake,
    required this.onSkip,
  });

  final DoseLog dose;
  final bool overdue;
  final bool busy;
  final VoidCallback onTake;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isPending = dose.status == DoseStatus.pending;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: overdue ? context.medora.dangerContainer.withValues(alpha: 0.3) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Column(
                  children: [
                    Text(
                      dose.scheduledTime.timeFormatted,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    if (overdue)
                      Text(
                        l10n.overdue,
                        style: TextStyle(
                          color: context.medora.danger,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dose.medicationName ?? l10n.unknownMedication,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dose.displayDosage != null)
                      Text(
                        dose.displayDosage!,
                        style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 13),
                      ),
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
                                  Icon(Icons.medical_services, size: 11, color: context.colors.onSurfaceVariant),
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
                            ...dose.patientTags.map((t) => TagChip(label: t, fontSize: 10, icon: Icons.person)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (isPending)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: busy ? null : onSkip,
                      icon: const Icon(Icons.skip_next, size: 20),
                      tooltip: l10n.skip,
                      color: context.medora.warning,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    FilledButton(
                      onPressed: busy ? null : onTake,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(64, 34),
                      ),
                      child: Text(l10n.take, style: const TextStyle(fontSize: 14)),
                    ),
                  ],
                )
              else
                _StatusBadge(dose: dose),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact status badge for a non-pending dose. For a taken dose it
/// folds the taken time into the same label ("Taken · 15:00") rather than
/// rendering it as a separate Text, so the plain status word stays unique
/// on screen even while an undo SnackBar (which also reads e.g. "Taken")
/// is visible.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.dose});

  final DoseLog dose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final medora = context.medora;

    final (bg, fg, icon, label) = switch (dose.status) {
      DoseStatus.taken => (medora.successContainer, medora.onSuccessContainer, Icons.check_circle, l10n.taken),
      DoseStatus.skipped => (medora.warningContainer, medora.onWarningContainer, Icons.skip_next, l10n.skipped),
      DoseStatus.missed => (medora.dangerContainer, medora.onDangerContainer, Icons.cancel, l10n.missed),
      DoseStatus.pending => (medora.neutralContainer, medora.onNeutralContainer, Icons.schedule, l10n.pending),
    };

    final text = (dose.status == DoseStatus.taken && dose.takenTime != null)
        ? '$label · ${dose.takenTime!.timeFormatted}'
        : label;

    return Chip(
      avatar: Icon(icon, color: fg, size: 18),
      label: Text(text),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 12),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
