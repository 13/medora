/// Medora - One prescription: what it is, what is left, and the actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/pharmacy_screen.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:share_plus/share_plus.dart';

enum _Action { edit, markDone, cancelRx, delete }

class RxDetailScreen extends ConsumerWidget {
  const RxDetailScreen({super.key, required this.rxId});

  final String rxId;

  /// Shows the generic error snackbar for a failed [Result], guarded by
  /// [context.mounted] (the caller has always just awaited something).
  void _reportFailure(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).genericError)),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    Rx rx,
    _Action action,
  ) async {
    final repo = ref.read(rxRepositoryProvider);
    final now = ref.read(nowProvider)();
    final l10n = AppLocalizations.of(context);
    switch (action) {
      case _Action.edit:
        await context.push(AppRoutes.editRx.replaceFirst(':id', rx.id));
        return;
      case _Action.markDone:
        final result = await repo.saveRx(
          rx.copyWith(closedOn: DateTime(now.year, now.month, now.day)),
        );
        if (!context.mounted) return;
        result.when(
          success: (_) => invalidateRx(ref),
          failure: (_) => _reportFailure(context),
        );
      case _Action.cancelRx:
        final result = await repo.saveRx(rx.copyWith(cancelled: true));
        if (!context.mounted) return;
        result.when(
          success: (_) => invalidateRx(ref),
          failure: (_) => _reportFailure(context),
        );
      case _Action.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.rxDelete),
            content: Text(l10n.rxDeleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.delete),
              ),
            ],
          ),
        );
        if (ok != true || !context.mounted) return;
        final result = await repo.deleteRx(rx.id);
        if (!context.mounted) return;
        result.when(
          success: (_) {
            invalidateRx(ref);
            Navigator.of(context).maybePop();
          },
          failure: (_) => _reportFailure(context),
        );
    }
  }

  Future<void> _share(BuildContext context, Rx rx, Person? person) async {
    final l10n = AppLocalizations.of(context);
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: l10n.rxShareText(rx.nre ?? '', person?.taxCode ?? ''),
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _linkMedication(
    BuildContext context,
    WidgetRef ref,
    Rx rx,
    RxItem item,
  ) async {
    final meds = await ref.read(medicationListProvider.future);
    if (!context.mounted) return;
    final word = item.description.split(' ').first.toLowerCase();
    final sorted = [...meds]
      ..sort((a, b) {
        final am = a.name.toLowerCase().contains(word) ? 0 : 1;
        final bm = b.name.toLowerCase().contains(word) ? 0 : 1;
        return am != bm ? am - bm : a.name.compareTo(b.name);
      });
    final picked = await showDialog<Medication>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(item.description),
        children: [
          for (final m in sorted)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: Text(m.name),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final result = await ref
        .read(rxRepositoryProvider)
        .saveRx(
          rx.copyWith(
            items: [
              for (final i in rx.items)
                i.id == item.id ? i.copyWith(medicationId: picked.id) : i,
            ],
          ),
        );
    if (!context.mounted) return;
    result.when(
      success: (_) => invalidateRx(ref),
      failure: (_) => _reportFailure(context),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final persons = ref.watch(personsProvider).value ?? const <Person>[];
    return AsyncValueView<RxWithDispensings>(
      value: ref.watch(rxByIdProvider(rxId)),
      onRetry: () async => ref.invalidate(rxByIdProvider(rxId)),
      data: (entry) {
        final rx = entry.rx;
        final person = persons.where((p) => p.id == rx.personId).firstOrNull;
        final status = entry.statusAt(now);
        final given = RxRules.dispensedPacks(entry.dispensings);
        final left = RxRules.daysLeft(rx, now);
        final canCollect =
            status == RxStatus.open || status == RxStatus.partial;
        return Scaffold(
          appBar: AppBar(
            title: Text(rxKindLabel(l10n, rx.kind)),
            actions: [
              if (rx.nre != null)
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: l10n.rxShare,
                  onPressed: () => _share(context, rx, person),
                ),
              PopupMenuButton<_Action>(
                onSelected: (a) => _onAction(context, ref, rx, a),
                itemBuilder: (_) => [
                  PopupMenuItem(value: _Action.edit, child: Text(l10n.edit)),
                  if (canCollect)
                    PopupMenuItem(
                      value: _Action.markDone,
                      child: Text(l10n.rxMarkDone),
                    ),
                  if (canCollect)
                    PopupMenuItem(
                      value: _Action.cancelRx,
                      child: Text(l10n.rxCancelRx),
                    ),
                  PopupMenuItem(
                    value: _Action.delete,
                    child: Text(l10n.rxDelete),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Chip(label: Text(rxStatusLabel(l10n, status))),
              if (canCollect && left != null) Text(l10n.rxDaysLeft(left)),
              if (canCollect && left == null && rx.priority != null)
                Text(
                  l10n.rxVisitBy(
                    RxValidity.visitBy(rx.priority!, rx.issuedOn).formatted,
                  ),
                ),
              const SizedBox(height: 8),
              if (person != null || rx.personId != null)
                DetailRow(
                  icon: Icons.person_outline,
                  label: l10n.rxPerson,
                  value: person?.name ?? l10n.rxUnknownPerson,
                ),
              if (rx.nre != null)
                DetailRow(icon: Icons.tag, label: l10n.rxNre, value: rx.nre!),
              DetailRow(
                icon: Icons.event_outlined,
                label: l10n.rxIssuedOn,
                value: rx.issuedOn.formatted,
              ),
              if (rx.validUntil != null)
                DetailRow(
                  icon: Icons.event_available_outlined,
                  label: l10n.rxValidUntil,
                  value: rx.validUntil!.formatted,
                ),
              if (rx.priority != null)
                DetailRow(
                  icon: Icons.flag_outlined,
                  label: l10n.rxPriority,
                  value: rxPriorityLabel(l10n, rx.priority!),
                ),
              if (rx.doctor != null)
                DetailRow(
                  icon: Icons.medical_services_outlined,
                  label: l10n.doctorLabel,
                  value: rx.doctor!,
                ),
              if (rx.exemptionCode != null)
                DetailRow(
                  icon: Icons.verified_outlined,
                  label: l10n.rxExemption,
                  value: rx.exemptionCode!,
                ),
              if (rx.notes != null)
                DetailRow(
                  icon: Icons.notes,
                  label: l10n.notes,
                  value: rx.notes!,
                ),
              const SizedBox(height: 16),
              if (rx.nre != null && canCollect)
                FilledButton.icon(
                  key: const Key('rx_show_pharmacy'),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.rxShowAtPharmacy),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PharmacyScreen(
                        nre: rx.nre!,
                        taxCode: person?.taxCode,
                        title: person?.name ?? rxKindLabel(l10n, rx.kind),
                      ),
                    ),
                  ),
                ),
              if (canCollect && rx.items.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('rx_redeem'),
                  icon: const Icon(Icons.local_pharmacy_outlined),
                  label: Text(l10n.rxRedeem),
                  onPressed: () => showRedeemSheet(context, ref, entry),
                ),
              const SizedBox(height: 16),
              Text(l10n.rxItems, style: Theme.of(context).textTheme.titleSmall),
              for (final i in rx.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.description),
                  subtitle: Text(
                    [
                      '${given[i.id] ?? 0} / ${i.packs}',
                      if (i.nonSubstitutable) l10n.rxNonSubstitutable,
                    ].join(' · '),
                  ),
                  trailing: i.medicationId == null
                      ? IconButton(
                          icon: const Icon(Icons.link),
                          tooltip: l10n.rxAddToStock,
                          onPressed: () => _linkMedication(context, ref, rx, i),
                        )
                      : const Icon(Icons.inventory_2_outlined),
                ),
              if (entry.dispensings.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.rxCollections,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final d in entry.dispensings)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      rx.items
                              .where((i) => i.id == d.itemId)
                              .firstOrNull
                              ?.description ??
                          '',
                    ),
                    subtitle: Text(
                      [
                        d.dispensedOn.formatted,
                        '${d.packs}×',
                        ?d.pharmacy,
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.undo),
                      tooltip: l10n.rxRemoveCollection,
                      onPressed: () async {
                        final result = await ref
                            .read(rxRepositoryProvider)
                            .undoDispensing(d.id);
                        if (!context.mounted) return;
                        result.when(
                          success: (_) => invalidateRx(ref),
                          failure: (_) => _reportFailure(context),
                        );
                      },
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
