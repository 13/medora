/// Medora - Dose Schedule Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/dose/widgets/date_strip.dart';
import 'package:medora/presentation/screens/dose/widgets/dose_card.dart';
import 'package:medora/presentation/screens/dose/widgets/dose_summary_header.dart';
import 'package:medora/presentation/screens/dose/widgets/time_groups.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/settings_action.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class DoseScheduleScreen extends ConsumerStatefulWidget {
  const DoseScheduleScreen({super.key});

  @override
  ConsumerState<DoseScheduleScreen> createState() => _DoseScheduleScreenState();
}

class _DoseScheduleScreenState extends ConsumerState<DoseScheduleScreen> {
  final Set<String> _busyIds = {};
  bool _takeAllBusy = false;

  @override
  Widget build(BuildContext context) {
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
          const SettingsAction(),
        ],
      ),
      body: Column(
        children: [
          DateStrip(today: today, selected: selected, now: now),
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
                onRetry: () async =>
                    ref.invalidate(dosesForDayProvider(selected)),
                data: (doses) =>
                    _buildDay(context, l10n, doses, now, selected, today),
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
    DateTime today,
  ) {
    Future<void> onRefresh() async {
      ref.invalidate(dosesForDayProvider(selected));
      await ref.read(dosesForDayProvider(selected).future);
    }

    if (doses.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // At least 60 % of the screen, so the message sits in the middle,
            // but never less than it needs: at a large text scale a fixed
            // height cut it off at the bottom.
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: EmptyStateWidget(
                icon: Icons.check_circle_outline,
                title: selected == today
                    ? l10n.noDosesScheduledToday
                    : l10n.noDosesForThisDay,
                subtitle: l10n.createTreatmentForDoses,
              ),
            ),
          ],
        ),
      );
    }

    final pendingDue = doses
        .where(
          (d) =>
              d.status == DoseStatus.pending && !d.scheduledTime.isAfter(now),
        )
        .toList();
    final showTakeAllDue = pendingDue.length >= 2;
    final groups = timeOfDayGroups(doses, l10n);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          DoseSummaryHeader(doses: doses),
          const SizedBox(height: 16),
          if (showTakeAllDue) ...[
            FilledButton.tonalIcon(
              onPressed: _takeAllBusy
                  ? null
                  : () =>
                        _handleTakeAllDue(pendingDue.map((d) => d.id).toList()),
              icon: const Icon(Icons.done_all),
              label: Text(l10n.takeAllDue),
            ),
            const SizedBox(height: 16),
          ],
          for (final group in groups) ...[
            GroupHeader(
              label: group.label,
              taken: group.taken,
              total: group.doses.length,
            ),
            const SizedBox(height: 6),
            ...group.doses.map(
              (dose) => DoseCard(
                key: ValueKey(dose.id),
                dose: dose,
                overdue:
                    dose.status == DoseStatus.pending &&
                    dose.scheduledTime.isBefore(now),
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
    // Captured before the SnackBar is shown: the shell swaps tabs by index,
    // so this screen (and its `ref`) can be disposed while the SnackBar is
    // re-hosted by the ScaffoldMessenger. `DoseActions` holds a provider
    // Ref and outlives the widget; `ref.read` at tap time would throw.
    final actions = ref.read(doseActionsProvider);
    try {
      final ok = await actions.take(id);
      if (!mounted) return;
      if (ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.doseTaken),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => _handleUndoTake(actions, messenger, l10n, id),
            ),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _handleSkip(String id) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyIds.add(id));
    final messenger = ScaffoldMessenger.of(context);
    // See _handleTake: the action object must outlive this widget.
    final actions = ref.read(doseActionsProvider);
    try {
      final ok = await actions.skip(id);
      if (!mounted) return;
      if (ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.doseSkipped),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => _handleUndoSkip(actions, messenger, l10n, id),
            ),
          ),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  /// Undo handlers run from a SnackBar action, i.e. potentially after this
  /// screen was disposed by a tab switch — so they take the already-captured
  /// [actions]/[messenger]/[l10n] rather than touching `ref` or `context`.
  Future<void> _handleUndoTake(
    DoseActions actions,
    ScaffoldMessengerState messenger,
    AppLocalizations l10n,
    String id,
  ) async {
    if (await actions.undoTake(id)) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
  }

  Future<void> _handleUndoSkip(
    DoseActions actions,
    ScaffoldMessengerState messenger,
    AppLocalizations l10n,
    String id,
  ) async {
    if (await actions.undoSkip(id)) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
  }

  Future<void> _handleTakeAllDue(List<String> ids) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _takeAllBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    // See _handleTake: the action object must outlive this widget.
    final actions = ref.read(doseActionsProvider);
    try {
      final taken = await actions.takeAllDue(ids);
      if (!mounted || taken.isEmpty) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.dosesTakenCount(taken.length)),
          action: SnackBarAction(
            label: l10n.undo,
            onPressed: () async {
              for (final id in taken) {
                await actions.undoTake(id);
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _takeAllBusy = false);
    }
  }
}
