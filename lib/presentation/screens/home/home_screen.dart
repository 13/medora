/// Medora - Home / Dashboard Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/medication_expiry_tile.dart';
import 'package:medora/presentation/widgets/settings_action.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sick_leave_badge.dart';
import 'package:medora/presentation/widgets/sync_status_chip.dart';
import 'package:medora/presentation/widgets/update_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final caps = ref.watch(platformCapabilitiesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboard),
        actions: [
          if (caps.hasCamera)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: l10n.scanBarcodeTooltip,
              onPressed: () => context.push(AppRoutes.scanner),
            ),
          const SyncStatusChip(),
          const SettingsAction(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // The derived lists only re-filter what the source providers
          // already hold, so invalidating them alone never re-read the
          // database: a row written by a sync pull stayed invisible until
          // the next cold start. Invalidate the sources; the derived lists
          // follow.
          ref.invalidate(medicationListProvider);
          ref.invalidate(treatmentListProvider);
          ref.invalidate(todaysDoseLogsProvider);
          try {
            // Awaited, so the spinner retracts for an honest reason. Note
            // that it is honest about the *read*: TodaysDoseLogsNotifier
            // generates any missing dose logs in the background and returns
            // as soon as the fetch lands, so doses materialized by this
            // pull can appear a moment after the spinner has gone.
            await Future.wait<Object>([
              ref.read(medicationListProvider.future),
              ref.read(treatmentListProvider.future),
              ref.read(todaysDoseLogsProvider.future),
            ]);
          } on Exception catch (_) {
            // The cards render the failure themselves; here it only has to
            // stop the spinner instead of escaping as an unhandled error.
            // Deliberately not a bare `catch`: an Error is a bug in a
            // build(), and swallowing it would leave the console silent.
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // A pending update, if one is known and not dismissed; hidden
            // otherwise, so it costs Home nothing in the normal case.
            const UpdateBanner(),

            // Now: the single next actionable dose (or a done/empty state).
            const _NowCard(),
            const SizedBox(height: 16),

            // At-a-glance counts, tappable to jump to the relevant tab.
            const _StatTiles(),
            const SizedBox(height: 16),

            // Today's overall progress bar (only rendered when there are
            // doses scheduled today).
            const _TodayProgress(),

            // Active Treatments
            _SectionHeader(
              title: l10n.activeTreatments,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(2),
            ),
            const _ActiveTreatmentsCard(),
            const SizedBox(height: 16),

            // Expired & expiring: one card, expired rows first.
            _SectionHeader(
              // Not `expiringSoon`: the rows underneath say "Expired", and
              // "Bald ablaufend" / "In scadenza" mean *about to* expire.
              title: l10n.expiringOrExpired,
              // Not the medications tab: that opens unfiltered and sorted by
              // name, so the dashboard's count and the list it links to
              // disagreed. This route shows the same set in the same order.
              onSeeAll: () => context.push(AppRoutes.expiringMedications),
            ),
            const _ExpiringSoonCard(),
            const SizedBox(height: 16),

            // Low Stock
            _SectionHeader(
              title: l10n.lowStock,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(1),
            ),
            const _LowStockCard(),
          ],
        ),
      ),
    );
  }
}

/// The single most relevant thing to do right now: take (or skip) the next
/// due dose, or a confirmation that everything is handled.
class _NowCard extends ConsumerStatefulWidget {
  const _NowCard();

  @override
  ConsumerState<_NowCard> createState() => _NowCardState();
}

class _NowCardState extends ConsumerState<_NowCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dosesAsync = ref.watch(todaysDoseLogsProvider);
    final nextDose = ref.watch(nextDueDoseProvider);
    final now = ref.watch(nowProvider)();

    return Card(
      color: context.colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AsyncValueView<List<DoseLog>>(
          value: dosesAsync,
          compact: true,
          onRetry: () async => ref.invalidate(todaysDoseLogsProvider),
          loading: SizedBox(
            height: 72,
            child: Center(
              child: CircularProgressIndicator(
                color: context.colors.onPrimaryContainer,
              ),
            ),
          ),
          data: (doses) {
            if (nextDose != null) {
              return _buildNextDose(context, l10n, nextDose, now);
            }
            if (doses.isNotEmpty) {
              return _buildAllDone(context, l10n);
            }
            return _buildEmpty(context, l10n);
          },
        ),
      ),
    );
  }

  Widget _buildNextDose(
    BuildContext context,
    AppLocalizations l10n,
    DoseLog dose,
    DateTime now,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.nextDose,
          style: context.text.labelMedium?.copyWith(
            color: context.colors.onPrimaryContainer.withValues(alpha: 0.8),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                dose.medicationName ?? '',
                style: context.text.headlineSmall?.copyWith(
                  color: context.colors.onPrimaryContainer,
                ),
              ),
            ),
            if (dose.isOverdueAt(now)) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: context.medora.dangerContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.overdue,
                  style: context.text.labelSmall?.copyWith(
                    color: context.medora.onDangerContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${dosageLabel(l10n, dose) ?? ''} · ${dose.scheduledTime.timeFormatted}',
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onPrimaryContainer.withValues(alpha: 0.8),
          ),
        ),
        const SizedBox(height: 16),
        // Wrap, not Row. "Einnehmen" beside "Überspringen" already overflows
        // this card by 2.3 dp on a 360 dp phone at a 1.0x text scale, and by
        // 83 dp at 1.6x - a striped overflow bar across the only two actions
        // the dashboard offers. A Wrap places the two buttons exactly where
        // the Row did while they fit, and moves Skip onto its own line when
        // they stop fitting.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _handleTake(context, l10n, dose.id),
              icon: const Icon(Icons.check),
              label: Text(l10n.take),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _handleSkip(context, l10n, dose.id),
              child: Text(l10n.skip),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAllDone(BuildContext context, AppLocalizations l10n) {
    return Row(
      children: [
        Icon(Icons.check_circle, color: context.colors.onPrimaryContainer),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            l10n.allDosesDone,
            style: context.text.titleMedium?.copyWith(
              color: context.colors.onPrimaryContainer,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.noDosesScheduled,
          style: context.text.titleMedium?.copyWith(
            color: context.colors.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => context.push(AppRoutes.addTreatment),
            child: Text(l10n.addTreatment),
          ),
        ),
      ],
    );
  }

  Future<void> _handleTake(
    BuildContext context,
    AppLocalizations l10n,
    String id,
  ) async {
    setState(() => _busy = true);
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
              onPressed: () => actions.undoTake(id),
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleSkip(
    BuildContext context,
    AppLocalizations l10n,
    String id,
  ) async {
    setState(() => _busy = true);
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
              onPressed: () => actions.undoSkip(id),
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
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Row of three at-a-glance counts, each tapping into the relevant tab.
class _StatTiles extends ConsumerWidget {
  const _StatTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final expiringMeds = ref.watch(expiringSoonProvider).value ?? const [];
    final expiring = expiringMeds.length;
    final lowStock = ref.watch(lowStockProvider).value?.length ?? 0;
    final treatments = ref.watch(activeTreatmentsProvider).value?.length ?? 0;
    // The count covers both states, so an amber number over a red "Expired"
    // row would understate what the card below it is saying.
    final anyExpired = expiringMeds.any(
      (m) => m.expiredAt(ref.watch(nowProvider)()),
    );

    return Row(
      children: [
        _StatTile(
          label: l10n.statExpiring,
          value: expiring,
          color: anyExpired ? context.medora.danger : context.medora.warning,
          // The same list the section header opens: the count and the list it
          // leads to have to agree.
          onTap: () => context.push(AppRoutes.expiringMedications),
        ),
        const SizedBox(width: 12),
        _StatTile(
          label: l10n.statLowStock,
          value: lowStock,
          color: context.medora.warning,
          onTap: () => MainShellScope.of(context)?.switchTab(1),
        ),
        const SizedBox(width: 12),
        _StatTile(
          label: l10n.statTreatments,
          value: treatments,
          color: context.colors.primary,
          onTap: () => MainShellScope.of(context)?.switchTab(2),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
  });

  final String label;
  final int value;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final numberColor = value == 0 ? context.colors.onSurfaceVariant : color;
    return Expanded(
      child: Card(
        // The card theme adds 12 dp of margin either side (theme.dart:43,
        // :108) — 24 dp off a tile that is only ~101 dp wide on a 360 dp
        // phone, which is what pushed the single-word labels past their box.
        // The Row's SizedBox gaps already space the three tiles apart.
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$value',
                  style: context.text.headlineMedium?.copyWith(
                    color: numberColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                // Shrink to fit, rather than wrap. A word wider than its line
                // is broken by Skia at an arbitrary character - it is not
                // clipped and not ellipsized - so "Behandlungen" split as
                // "Behandlun / gen" from a text scale of about 1.06, which is
                // one notch of Android's font-size slider and exactly the bug
                // this tile was reported for. BoxFit.scaleDown only ever
                // shrinks, and every label fits the tile unscaled, so the
                // caption still grows with the user's setting until it
                // reaches the tile's width and then holds there instead of
                // breaking. The ellipsis is a backstop for a future label
                // long enough to be unreadable when scaled down.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin progress bar summarizing today's scheduled doses, hidden when there
/// are none. A dose logged for an as-needed prescription was never scheduled,
/// so it counts in neither number.
class _TodayProgress extends ConsumerWidget {
  const _TodayProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dosesAsync = ref.watch(todaysDoseLogsProvider);

    return dosesAsync.maybeWhen(
      data: (all) {
        final doses = all.where((d) => !d.asNeeded).toList();
        final total = doses.length;
        if (total == 0) return const SizedBox.shrink();
        final taken = doses.where((d) => d.status == DoseStatus.taken).length;
        final pending = doses
            .where((d) => d.status == DoseStatus.pending)
            .length;

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: taken / total,
                  minHeight: 4,
                  backgroundColor: context.colors.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.dosesProgress(taken, total, pending),
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onSeeAll});

  final String title;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Expanded + ellipsis: at a 2.0x text scale a long section title
        // and the "See all" button no longer fit side by side.
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(onPressed: onSeeAll, child: Text(l10n.seeAll)),
      ],
    );
  }
}

class _ExpiringSoonCard extends ConsumerWidget {
  const _ExpiringSoonCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final expiringAsync = ref.watch(expiringSoonProvider);
    final now = ref.watch(nowProvider)();

    return AsyncValueView<List<Medication>>(
      value: expiringAsync,
      compact: true,
      // The source list is the only place a cabinet read can fail, so a
      // retry that re-awaited the derived provider alone re-awaited the
      // same failure and could never recover. Invalidating the source is
      // the whole fix: a derived list re-runs when its source does, which
      // is exactly what pull-to-refresh relies on.
      onRetry: () async => ref.invalidate(medicationListProvider),
      emptyWhen: (meds) => meds.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.allMedicationsWithinDate,
        ),
      ),
      data: (meds) {
        final shown = meds.take(3).toList();
        final hidden = meds.length - shown.length;
        return Card(
          child: Column(
            children: [
              for (final med in shown) MedicationExpiryTile(med: med, now: now),
              // The three slots go to the most urgent rows, so once expired
              // and expiring medications share the card the merely-expiring
              // ones fall off the bottom. Without this the card looks
              // complete while disagreeing with its own stat tile.
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => context.push(AppRoutes.expiringMedications),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LowStockCard extends ConsumerWidget {
  const _LowStockCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final lowStockAsync = ref.watch(lowStockProvider);

    return AsyncValueView<List<Medication>>(
      value: lowStockAsync,
      compact: true,
      // See _ExpiringSoonCard: the derived list cannot recover on its own.
      onRetry: () async => ref.invalidate(medicationListProvider),
      emptyWhen: (meds) => meds.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.allMedicationsWellStocked,
        ),
      ),
      data: (meds) {
        final hidden = meds.length - 3;
        return Card(
          child: Column(
            children: [
              ...meds.take(3).map((med) {
                return ListTile(
                  leading: Icon(
                    Icons.inventory_2_outlined,
                    color: context.medora.warning,
                  ),
                  title: Text(med.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (med.category != null)
                        Text(
                          AppConstants.categoryLabel(l10n, med.category!),
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (med.patientTags.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: med.patientTags
                              .map((t) => TagChip(label: t, fontSize: 10))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                  // Shrink to fit. A ListTile gives its trailing slot the
                  // tile's own height, and the count stacked over "Left"
                  // overflows that by 12 dp from a 1.6x text scale. The stat
                  // tiles already solve the same problem the same way:
                  // BoxFit.scaleDown only ever shrinks, so at every ordinary
                  // text scale this paints what it painted before.
                  trailing: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${med.quantity}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: context.medora.warning,
                          ),
                        ),
                        Text(
                          l10n.leftLabel,
                          style: TextStyle(
                            fontSize: 10,
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  dense: true,
                  onTap: () => context.push('/medications/${med.id}'),
                );
              }),
              // As on the expiry card: the stat tile counts every one of
              // them, so the card says how many it does not show.
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => MainShellScope.of(context)?.switchTab(1),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ActiveTreatmentsCard extends ConsumerWidget {
  const _ActiveTreatmentsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(activeTreatmentsProvider);
    final now = ref.watch(nowProvider)();

    return AsyncValueView<List<Treatment>>(
      value: treatmentsAsync,
      compact: true,
      // See _ExpiringSoonCard: the derived list cannot recover on its own.
      onRetry: () async => ref.invalidate(treatmentListProvider),
      emptyWhen: (treatments) => treatments.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.noActiveTreatments,
        ),
      ),
      data: (treatments) {
        final hidden = treatments.length - 3;
        return Card(
          child: Column(
            children: [
              for (final t in treatments.take(3))
                _ActiveTreatmentTile(treatment: t, now: now),
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => MainShellScope.of(context)?.switchTab(2),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The last row of a dashboard card that has more than three rows: how many
/// it does not show, and where to see them.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const Key('dashboardMoreRow'),
      dense: true,
      leading: const Icon(Icons.more_horiz),
      title: Text(AppLocalizations.of(context).moreCount(count)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _ActiveTreatmentTile extends StatelessWidget {
  const _ActiveTreatmentTile({required this.treatment, required this.now});
  final Treatment treatment;

  /// "Now" from the card's `nowProvider`, for the sick-leave day count.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ListTile(
      leading: Icon(Icons.healing, color: context.colors.primary),
      title: Text(
        treatment.name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.startedOn(treatment.startDate.formatted),
            style: const TextStyle(fontSize: 12),
          ),
          // Only a leave that is running today: one planned for next week
          // would read as if the user were off work now.
          if (treatment.isSickLeaveOpen &&
              treatment.sickLeaveDaysAt(now) != null) ...[
            const SizedBox(height: 4),
            SickLeaveBadge(
              key: const Key('sickLeaveBadge'),
              treatment: treatment,
              now: now,
              fontSize: 10,
            ),
          ],
          if (treatment.patientTags.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: treatment.patientTags
                  .map(
                    (t) => TagChip(label: t, fontSize: 10, icon: Icons.person),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
      trailing: Icon(Icons.chevron_right, color: context.colors.outline),
      dense: true,
      onTap: () => context.push('/treatments/${treatment.id}'),
    );
  }
}
