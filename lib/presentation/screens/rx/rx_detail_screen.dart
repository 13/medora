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
import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/pharmacy_screen.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';
import 'package:medora/presentation/screens/rx/rx_attachments_section.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:share_plus/share_plus.dart';

enum _Action { edit, markDone, cancelRx, delete }

/// The text shared for [nre]/[taxCode] (and a white prescription's [pin]):
/// with the tax code and PIN when on file, NRE-only otherwise. Pure so
/// it's testable without the `share_plus` platform channel.
String rxShareMessage(
  AppLocalizations l10n,
  String? nre,
  String? taxCode, {
  String? pin,
}) {
  final number = nre ?? '';
  final hasTaxCode = taxCode != null && taxCode.isNotEmpty;
  if (pin != null && pin.isNotEmpty) {
    return hasTaxCode
        ? l10n.rxShareTextPin(number, pin, taxCode)
        : l10n.rxShareTextPinNoTaxCode(number, pin);
  }
  return hasTaxCode
      ? l10n.rxShareText(number, taxCode)
      : l10n.rxShareTextNreOnly(number);
}

bool _isWhite(RxKind kind) =>
    kind == RxKind.white || kind == RxKind.whiteRepeatable;

/// The label of [rx]'s number: NRBE for the white kinds, NRE otherwise.
String rxNumberLabel(AppLocalizations l10n, RxKind kind) =>
    _isWhite(kind) ? l10n.rxNrbe : l10n.rxNre;

/// The barcodes to print at the pharmacy, like the paper: an SSN/referral
/// NRE as its two printed halves, a white NRBE followed by its PIN when
/// set, then the person's tax code when known. Pure so it's testable
/// without pumping a widget.
List<PharmacyCode> pharmacyCodesFor(
  AppLocalizations l10n,
  Rx rx,
  String? taxCode,
) {
  final codes = <PharmacyCode>[];
  final nre = rx.nre;
  if (nre != null) {
    final halves = Nre.split(nre);
    if (halves != null) {
      codes.add(PharmacyCode(label: l10n.rxNrePart1, value: halves.$1));
      codes.add(PharmacyCode(label: l10n.rxNrePart2, value: halves.$2));
    } else if (Nre.isNrbe(nre)) {
      codes.add(PharmacyCode(label: l10n.rxNrbe, value: nre));
      final pin = rx.pin;
      if (pin != null && pin.isNotEmpty) {
        codes.add(PharmacyCode(label: l10n.rxPin, value: pin));
      }
    } else if (nre.isNotEmpty) {
      // A number stored before the NRE/NRBE shapes were enforced: print it
      // whole rather than not at all.
      codes.add(PharmacyCode(label: rxNumberLabel(l10n, rx.kind), value: nre));
      if (_isWhite(rx.kind)) {
        final pin = rx.pin;
        if (pin != null && pin.isNotEmpty) {
          codes.add(PharmacyCode(label: l10n.rxPin, value: pin));
        }
      }
    }
  }
  if (taxCode != null && taxCode.isNotEmpty) {
    codes.add(PharmacyCode(label: l10n.rxTaxCode, value: taxCode));
  }
  return codes;
}

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
          // Pop, and invalidate only the lists — not rxByIdProvider(rx.id):
          // the route is still mounted during the pop animation, so
          // invalidating the deleted prescription's own provider would
          // refetch it and flash the error view underneath before the
          // route is gone.
          //
          // A notification tap can land here with nothing to pop to (a
          // leaf route pushed straight onto the shell): `maybePop` would
          // then do nothing and strand the user on a deleted prescription,
          // so fall back to home.
          success: (_) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).maybePop();
            } else {
              context.go(AppRoutes.home);
            }
            invalidateRxLists(ref);
          },
          failure: (_) => _reportFailure(context),
        );
    }
  }

  Future<void> _share(BuildContext context, Rx rx, Person? person) async {
    final l10n = AppLocalizations.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final text = rxShareMessage(l10n, rx.nre, person?.taxCode, pin: rx.pin);
    await SharePlus.instance.share(
      ShareParams(
        text: text,
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
    final List<Medication> meds;
    try {
      meds = await ref.read(medicationListProvider.future);
    } catch (_) {
      if (!context.mounted) return;
      _reportFailure(context);
      return;
    }
    if (!context.mounted) return;
    // Nothing to link to: don't pop up an empty picker.
    if (meds.isEmpty) return;
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
      // The `data` branch below builds its own full Scaffold (title, share
      // and menu actions); loading/error otherwise render with no AppBar,
      // no back button and (for the error view's button) no Material
      // ancestor.
      nonDataWrapper: (child) => Scaffold(appBar: AppBar(), body: child),
      data: (entry) {
        final rx = entry.rx;
        final person = persons.where((p) => p.id == rx.personId).firstOrNull;
        final status = entry.statusAt(now);
        final given = RxRules.dispensedPacks(entry.dispensings);
        final left = RxRules.daysLeft(rx, now);
        final canCollect =
            status == RxStatus.open || status == RxStatus.partial;
        final pharmacyCodes = pharmacyCodesFor(l10n, rx, person?.taxCode);
        // A notification tap opens this screen with home landed on first
        // (see `ReminderService._openRxDetail`), but a defensive fallback
        // still belongs here: with nothing to pop to, the default AppBar
        // would show no back button at all, so add one that goes home
        // instead of leaving the user stranded.
        final canPop = Navigator.of(context).canPop();
        return Scaffold(
          appBar: AppBar(
            leading: canPop
                ? null
                : IconButton(
                    key: const Key('rx_detail_go_home'),
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => context.go(AppRoutes.home),
                  ),
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
                DetailRow(
                  icon: Icons.tag,
                  label: rxNumberLabel(l10n, rx.kind),
                  value: rx.nre!,
                ),
              if (rx.pin case final pin? when pin.isNotEmpty)
                DetailRow(
                  icon: Icons.pin_outlined,
                  label: l10n.rxPin,
                  value: pin,
                ),
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
              if (canCollect && pharmacyCodes.isNotEmpty)
                FilledButton.icon(
                  key: const Key('rx_show_pharmacy'),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.rxShowAtPharmacy),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PharmacyScreen(
                        codes: pharmacyCodes,
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
                      if (i.posology case final p? when p.isNotEmpty) p,
                    ].join(' · '),
                  ),
                  trailing: i.medicationId == null
                      ? IconButton(
                          icon: const Icon(Icons.link),
                          tooltip: l10n.rxLinkMedication,
                          onPressed: () => _linkMedication(context, ref, rx, i),
                        )
                      : const Icon(Icons.inventory_2_outlined),
                ),
              const SizedBox(height: 16),
              RxAttachmentsSection(rxId: rx.id),
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
                    trailing: _RemoveCollectionButton(
                      dispensingId: d.id,
                      onFailure: _reportFailure,
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

/// Removes one collection after asking; off while the removal runs, so a
/// second tap cannot send it twice.
class _RemoveCollectionButton extends ConsumerStatefulWidget {
  const _RemoveCollectionButton({
    required this.dispensingId,
    required this.onFailure,
  });

  final String dispensingId;
  final void Function(BuildContext context) onFailure;

  @override
  ConsumerState<_RemoveCollectionButton> createState() =>
      _RemoveCollectionButtonState();
}

class _RemoveCollectionButtonState
    extends ConsumerState<_RemoveCollectionButton> {
  bool _busy = false;

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      final l10n = AppLocalizations.of(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(l10n.rxRemoveCollectionConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.rxRemoveCollection),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final result = await ref
          .read(rxRepositoryProvider)
          .undoDispensing(widget.dispensingId);
      if (!mounted) return;
      result.when(
        success: (_) => invalidateRx(ref),
        failure: (_) => widget.onFailure(context),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.undo),
    tooltip: AppLocalizations.of(context).rxRemoveCollection,
    onPressed: _busy ? null : _remove,
  );
}
