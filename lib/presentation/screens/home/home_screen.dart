/// Medora - Home / Dashboard Screen
library;

import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sync_status_chip.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
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
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(expiringSoonProvider);
          ref.invalidate(lowStockProvider);
          ref.invalidate(activeTreatmentsProvider);
          ref.invalidate(todaysDoseLogsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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

            // Expiring Soon
            _SectionHeader(
              title: l10n.expiringSoon,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(1),
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
              child: CircularProgressIndicator(color: context.colors.onPrimaryContainer),
            ),
          ),
          data: (doses) {
            if (nextDose != null) {
              return _buildNextDose(context, l10n, nextDose);
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

  Widget _buildNextDose(BuildContext context, AppLocalizations l10n, DoseLog dose) {
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
                style: context.text.headlineSmall?.copyWith(color: context.colors.onPrimaryContainer),
              ),
            ),
            if (dose.isOverdue) ...[
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
          '${dose.displayDosage ?? ''} · ${dose.scheduledTime.timeFormatted}',
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onPrimaryContainer.withValues(alpha: 0.8),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _handleTake(context, l10n, dose.id),
              icon: const Icon(Icons.check),
              label: Text(l10n.take),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : () => _handleSkip(context, l10n, dose.id),
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
            style: context.text.titleMedium?.copyWith(color: context.colors.onPrimaryContainer),
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
          style: context.text.titleMedium?.copyWith(color: context.colors.onPrimaryContainer),
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

  Future<void> _handleTake(BuildContext context, AppLocalizations l10n, String id) async {
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
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(e.toString()))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleSkip(BuildContext context, AppLocalizations l10n, String id) async {
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
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(e.toString()))));
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
    final expiring = ref.watch(expiringSoonProvider).value?.length ?? 0;
    final lowStock = ref.watch(lowStockProvider).value?.length ?? 0;
    final treatments = ref.watch(activeTreatmentsProvider).value?.length ?? 0;

    return Row(
      children: [
        _StatTile(
          label: l10n.statExpiring,
          value: expiring,
          color: context.medora.warning,
          onTap: () => MainShellScope.of(context)?.switchTab(1),
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
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: context.text.labelMedium?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin progress bar summarizing today's doses, hidden when there are none.
class _TodayProgress extends ConsumerWidget {
  const _TodayProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dosesAsync = ref.watch(todaysDoseLogsProvider);

    return dosesAsync.maybeWhen(
      data: (doses) {
        final total = doses.length;
        if (total == 0) return const SizedBox.shrink();
        final taken = doses.where((d) => d.status == DoseStatus.taken).length;
        final pending = doses.where((d) => d.status == DoseStatus.pending).length;

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
                style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
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
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        TextButton(
          onPressed: onSeeAll,
          child: Text(l10n.seeAll),
        ),
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

    return AsyncValueView<List<Medication>>(
      value: expiringAsync,
      compact: true,
      onRetry: () async => ref.invalidate(expiringSoonProvider),
      emptyWhen: (meds) => meds.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.allMedicationsWithinDate,
        ),
      ),
      data: (meds) {
        return Card(
          child: Column(
            children: meds.take(3).map((med) {
              final days = med.expiryDate?.difference(DateTime.now()).inDays;
              return ListTile(
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: context.medora.warning,
                ),
                title: Text(med.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (med.expiryDate != null)
                      Text(med.expiryDate!.formatted, style: const TextStyle(fontSize: 12)),
                    if (med.patientTags.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: med.patientTags.map((t) => TagChip(label: t, fontSize: 10)).toList(),
                      ),
                    ],
                  ],
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${days ?? 0}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: context.medora.warning,
                      ),
                    ),
                    Text(
                      l10n.daysLabel,
                      style: TextStyle(fontSize: 10, color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
                dense: true,
                onTap: () => context.push('/medications/${med.id}'),
              );
            }).toList(),
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
      onRetry: () async => ref.invalidate(lowStockProvider),
      emptyWhen: (meds) => meds.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.allMedicationsWellStocked,
        ),
      ),
      data: (meds) {
        return Card(
          child: Column(
            children: meds.take(3).map((med) {
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
                      Text(AppConstants.categoryLabel(l10n, med.category!), style: const TextStyle(fontSize: 12)),
                    if (med.patientTags.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: med.patientTags.map((t) => TagChip(label: t, fontSize: 10)).toList(),
                      ),
                    ],
                  ],
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
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
                      style: TextStyle(fontSize: 10, color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
                dense: true,
                onTap: () => context.push('/medications/${med.id}'),
              );
            }).toList(),
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

    return AsyncValueView<List<Treatment>>(
      value: treatmentsAsync,
      compact: true,
      onRetry: () async => ref.invalidate(activeTreatmentsProvider),
      emptyWhen: (treatments) => treatments.isEmpty,
      empty: Card(
        child: EmptyStateWidget(
          compact: true,
          icon: Icons.check_circle,
          title: l10n.noActiveTreatments,
        ),
      ),
      data: (treatments) {
        return Card(
          child: Column(
            children: treatments.take(3).map((t) {
              return _ActiveTreatmentTile(treatment: t);
            }).toList(),
          ),
        );
      },
    );
  }
}

class _ActiveTreatmentTile extends StatelessWidget {
  const _ActiveTreatmentTile({required this.treatment});
  final Treatment treatment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ListTile(
      leading: Icon(Icons.healing, color: context.colors.primary),
      title: Text(treatment.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.startedOn(treatment.startDate.formatted), style: const TextStyle(fontSize: 12)),
          if (treatment.patientTags.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: treatment.patientTags.map((t) => TagChip(label: t, fontSize: 10, icon: Icons.person)).toList(),
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
