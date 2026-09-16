/// Medora - Treatment List Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/treatment/end_treatment_dialog.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/presentation/widgets/sick_leave_badge.dart';

/// Filter options for treatment list.
enum TreatmentFilter { active, ended, all }

class TreatmentListScreen extends ConsumerStatefulWidget {
  const TreatmentListScreen({super.key});

  @override
  ConsumerState<TreatmentListScreen> createState() =>
      _TreatmentListScreenState();
}

class _TreatmentListScreenState extends ConsumerState<TreatmentListScreen> {
  final _searchController = TextEditingController();
  bool _isSearching = false;
  TreatmentFilter _filter = TreatmentFilter.active;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Treatment> _applyFilter(List<Treatment> treatments) {
    var filtered = treatments;

    // Apply search query
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered.where((t) {
        return t.name.toLowerCase().contains(query) ||
            t.symptomTags.any((s) => s.toLowerCase().contains(query)) ||
            t.patientTags.any((p) => p.toLowerCase().contains(query)) ||
            (t.notes ?? '').toLowerCase().contains(query) ||
            (t.doctor ?? '').toLowerCase().contains(query);
      }).toList();
    }

    // Apply status filter
    return switch (_filter) {
      TreatmentFilter.all => filtered,
      TreatmentFilter.active => filtered.where((t) => t.isActive).toList(),
      TreatmentFilter.ended => filtered.where((t) => !t.isActive).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(treatmentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.searchTreatments,
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text(l10n.treatments),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchController.clear();
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                _FilterChip(
                  label: l10n.active,
                  selected: _filter == TreatmentFilter.active,
                  onTap: () => setState(() => _filter = TreatmentFilter.active),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.ended,
                  selected: _filter == TreatmentFilter.ended,
                  onTap: () => setState(() => _filter = TreatmentFilter.ended),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: l10n.all,
                  selected: _filter == TreatmentFilter.all,
                  onTap: () => setState(() => _filter = TreatmentFilter.all),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Treatment list
          Expanded(
            child: AsyncValueView<List<Treatment>>(
              value: treatmentsAsync,
              onRetry: () async =>
                  ref.read(treatmentListProvider.notifier).refresh(),
              emptyWhen: (treatments) => treatments.isEmpty,
              empty: EmptyStateWidget(
                icon: Icons.healing_outlined,
                title: l10n.noTreatmentsYet,
                subtitle: l10n.createTreatmentPlan,
                actionLabel: l10n.addTreatment,
                onAction: () => context.push(AppRoutes.addTreatment),
              ),
              data: (treatments) {
                final filtered = _applyFilter(treatments);
                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: context.colors.outline,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.noResults,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    await ref.read(treatmentListProvider.notifier).refresh();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final t = filtered[index];
                      return Slidable(
                        endActionPane: ActionPane(
                          motion: const ScrollMotion(),
                          children: [
                            if (t.isActive)
                              SlidableAction(
                                // Asks first, like the detail screen: it
                                // is the same write, and the dialog is where
                                // an open sick leave can be ended too.
                                onPressed: (_) =>
                                    confirmAndEndTreatment(context, ref, t),
                                backgroundColor: context.medora.warning,
                                foregroundColor: context.medora.onWarning,
                                icon: Icons.stop_circle,
                                label: l10n.end,
                              ),
                            SlidableAction(
                              onPressed: (_) async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.deleteTreatment),
                                    content: Text(
                                      l10n.deleteTreatmentConfirm(t.name),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text(l10n.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text(
                                          l10n.delete,
                                          style: TextStyle(
                                            color: context.colors.error,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await ref
                                      .read(treatmentListProvider.notifier)
                                      .deleteTreatment(t.id);
                                }
                              },
                              backgroundColor: context.colors.error,
                              foregroundColor: context.colors.onError,
                              icon: Icons.delete,
                              label: l10n.delete,
                            ),
                          ],
                        ),
                        child: _TreatmentTile(treatment: t),
                      );
                    },
                  ),
                );
              },
              loading: LoadingWidget(message: l10n.loadingTreatments),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push(AppRoutes.addTreatment),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _TreatmentTile extends ConsumerWidget {
  const _TreatmentTile({required this.treatment});
  final Treatment treatment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final prescriptionsAsync = ref.watch(
      prescriptionsByTreatmentProvider(treatment.id),
    );

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: context.colors.primaryContainer,
        child: Icon(Icons.healing, color: context.colors.onPrimaryContainer),
      ),
      title: Text(
        treatment.name,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User and Symptoms
          if (treatment.patientName != null || treatment.symptomTags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (treatment.patientName != null)
                    ...treatment.patientTags.map(
                      (t) => TagChip(label: t, icon: Icons.person),
                    ),
                  ...treatment.symptomTags
                      .take(3)
                      .map((s) => TagChip(label: s)),
                ],
              ),
            ),

          // Status, started on and sick leave. A Wrap, not a Row: at
          // 360 dp and a large text scale the three do not fit one line.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: treatment.isActive
                        ? context.medora.successContainer
                        : context.colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    treatment.isActive ? l10n.active : l10n.ended,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: treatment.isActive
                          ? context.medora.onSuccessContainer
                          : context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  l10n.startedOn(treatment.startDate.shortFormatted),
                  style: TextStyle(
                    color: context.colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (treatment.hasSickLeave)
                  SickLeaveBadge(
                    key: const Key('sickLeaveBadge'),
                    treatment: treatment,
                    now: now,
                  ),
              ],
            ),
          ),
        ],
      ),
      // Cap the count, do not let it take the row. A ListTile hands its
      // trailing slot loose constraints (320 dp wide at 360 dp), so at a
      // 1.6x text scale German "Verschreibungen" claimed 138 dp and left the
      // name 110 dp: "Sinusitis" broke mid-word, the tag chips overflowed and
      // the column overflowed the tile's height as well.
      //
      // 0.28 of the slot is 89.6 dp at 360 dp. That is above the 86.5 dp
      // "Verschreibungen" needs at 1.0x, so an ordinary text scale paints
      // exactly what it painted before, and it leaves the name and the
      // sick-leave badge 158 dp at 1.6x, above the 154 dp the badge's
      // longest word needs. BoxFit.scaleDown only ever shrinks.
      trailing: prescriptionsAsync.maybeWhen(
        data: (prescriptions) => LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.28),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${prescriptions.length}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: context.colors.primary,
                    ),
                  ),
                  Text(
                    l10n.prescriptions,
                    style: TextStyle(
                      fontSize: 10,
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        loading: () => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        orElse: () => const SizedBox.shrink(),
      ),
      isThreeLine: true,
      onTap: () => context.push('/treatments/${treatment.id}'),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}
