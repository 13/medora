/// Medora - The prescriptions, grouped: open, partly collected, then done.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class RxListView extends ConsumerStatefulWidget {
  const RxListView({super.key});

  @override
  ConsumerState<RxListView> createState() => _RxListViewState();
}

class _RxListViewState extends ConsumerState<RxListView> {
  /// Null means "every person"; set from the dropdown below.
  String? _personFilter;

  /// Re-reads the prescriptions, like the other lists' pull-to-refresh:
  /// a row a sync pulled shows here at the latest after this.
  Future<void> _refresh() async {
    ref.invalidateRxData();
    try {
      await ref.read(rxListProvider.future);
    } on Exception catch (_) {
      // The list renders the failure itself; this only stops the spinner.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final personList = ref.watch(personsProvider).value ?? const <Person>[];
    final persons = {for (final p in personList) p.id: p};
    // The tab stays mounted while Settings -> Persons can delete the
    // filtered person out from under it; a stale id would otherwise leave
    // the dropdown showing a value with no matching item.
    if (_personFilter != null && !persons.containsKey(_personFilter)) {
      _personFilter = null;
    }
    // Only in effect while the dropdown that can change it is shown, so
    // dropping to one (or zero) persons never strands the list filtered
    // with no control left to clear it.
    final showFilter = personList.length > 1;
    final activeFilter = showFilter ? _personFilter : null;
    return AsyncValueView<List<RxWithDispensings>>(
      value: ref.watch(rxListProvider),
      onRetry: () async => ref.invalidate(rxListProvider),
      emptyWhen: (list) => list.isEmpty,
      empty: EmptyStateWidget(
        icon: Icons.receipt_long_outlined,
        title: l10n.rxNoneYet,
        subtitle: l10n.rxNoneYetHint,
        actionLabel: l10n.rxAdd,
        onAction: () => context.push(AppRoutes.addRx),
      ),
      data: (fullList) {
        final list = activeFilter == null
            ? fullList
            : [
                for (final r in fullList)
                  if (r.rx.personId == activeFilter) r,
              ];
        final open = <RxWithDispensings>[];
        final partial = <RxWithDispensings>[];
        final done = <RxWithDispensings>[];
        for (final r in list) {
          switch (r.statusAt(now)) {
            case RxStatus.open:
              open.add(r);
            case RxStatus.partial:
              partial.add(r);
            case RxStatus.redeemed || RxStatus.expired || RxStatus.cancelled:
              done.add(r);
          }
        }
        // Soonest last valid day first; unknown validity last.
        int byExpiry(RxWithDispensings a, RxWithDispensings b) {
          final x = a.rx.validUntil, y = b.rx.validUntil;
          if (x == null) return y == null ? 0 : 1;
          if (y == null) return -1;
          return x.compareTo(y);
        }

        open.sort(byExpiry);
        partial.sort(byExpiry);
        Widget tile(RxWithDispensings r) =>
            _RxTile(item: r, person: persons[r.rx.personId], now: now);
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (showFilter)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: DropdownButton<String?>(
                    value: _personFilter,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(child: Text(l10n.all)),
                      for (final p in personList)
                        DropdownMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    onChanged: (id) => setState(() => _personFilter = id),
                  ),
                ),
              for (final r in open) tile(r),
              if (partial.isNotEmpty) _Header(l10n.rxStatusPartial),
              for (final r in partial) tile(r),
              if (done.isNotEmpty)
                ExpansionTile(
                  title: Text(l10n.rxGroupDone),
                  children: [for (final r in done) tile(r)],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _RxTile extends StatelessWidget {
  const _RxTile({required this.item, required this.person, required this.now});

  final RxWithDispensings item;
  final Person? person;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rx = item.rx;
    final status = item.statusAt(now);
    final left = RxRules.daysLeft(rx, now);
    final priority = rx.priority;
    final validity = switch (status) {
      RxStatus.open ||
      RxStatus.partial when left != null => l10n.rxDaysLeft(left),
      RxStatus.open || RxStatus.partial when priority != null => l10n.rxVisitBy(
        RxValidity.visitBy(priority, rx.issuedOn).formatted,
      ),
      RxStatus.open || RxStatus.partial => null,
      _ => rxStatusLabel(l10n, status),
    };
    final title = rx.items.isEmpty
        ? rxKindLabel(l10n, rx.kind)
        : rx.items.map((i) => i.description).join(', ');
    return ListTile(
      leading: Chip(
        label: Text(rxKindShort(l10n, rx.kind)),
        visualDensity: VisualDensity.compact,
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        <String?>[
          person?.name ?? (rx.personId == null ? null : l10n.rxUnknownPerson),
          validity,
        ].nonNulls.join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.rxDetail.replaceFirst(':id', rx.id)),
    );
  }
}
