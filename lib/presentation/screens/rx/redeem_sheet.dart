/// Medora - Record what was collected at the pharmacy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:uuid/uuid.dart';

/// Units a collection of [packs] of [item] is proposed to add to stock.
int proposedUnits(RxItem item, int packs) =>
    packs * (RxRules.packSizeOf(item.description) ?? 1);

Future<void> showRedeemSheet(
  BuildContext context,
  WidgetRef ref,
  RxWithDispensings entry,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _RedeemSheet(entry: entry),
);

class _Line {
  _Line(this.item, int packs, {required this.addToStock})
    : packs = TextEditingController(text: '$packs'),
      units = TextEditingController(text: '${proposedUnits(item, packs)}');

  final RxItem item;
  final TextEditingController packs;
  final TextEditingController units;
  bool selected = true;
  bool addToStock;
}

class _RedeemSheet extends ConsumerStatefulWidget {
  const _RedeemSheet({required this.entry});
  final RxWithDispensings entry;

  @override
  ConsumerState<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends ConsumerState<_RedeemSheet> {
  final _pharmacy = TextEditingController();
  late final List<_Line> _lines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final given = RxRules.dispensedPacks(widget.entry.dispensings);
    _lines = [
      for (final i in widget.entry.rx.items)
        if ((given[i.id] ?? 0) < i.packs ||
            widget.entry.rx.maxDispensings != null)
          _Line(
            i,
            widget.entry.rx.maxDispensings != null
                ? i.packs
                : i.packs - (given[i.id] ?? 0),
            addToStock: i.medicationId != null,
          ),
    ];
  }

  @override
  void dispose() {
    _pharmacy.dispose();
    for (final l in _lines) {
      l.packs.dispose();
      l.units.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final now = ref.read(nowProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final pharmacy = _pharmacy.text.trim();
    final rx = widget.entry.rx;
    final dispensings = [
      for (final l in _lines)
        if (l.selected && (int.tryParse(l.packs.text) ?? 0) > 0)
          RxDispensing(
            id: const Uuid().v4(),
            rxId: rx.id,
            itemId: l.item.id,
            packs: int.parse(l.packs.text),
            dispensedOn: today,
            pharmacy: pharmacy.isEmpty ? null : pharmacy,
            unitsAdded: l.addToStock && l.item.medicationId != null
                ? int.tryParse(l.units.text) ?? 0
                : 0,
          ),
    ];
    final result = await ref
        .read(rxRepositoryProvider)
        .redeem(rx.id, dispensings);
    if (!mounted) return;
    invalidateRx(ref);
    ref.invalidate(medicationListProvider);
    result.when(
      success: (_) => Navigator.of(context).pop(),
      failure: (_) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).genericError)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.rxRedeemTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(l10n.rxNothingLeft),
            ),
          for (final l in _lines)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: l.selected,
                      title: Text(l.item.description),
                      onChanged: (v) => setState(() => l.selected = v ?? false),
                    ),
                    Row(
                      children: [
                        SizedBox(
                          width: 88,
                          child: TextField(
                            controller: l.packs,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.rxItemPacks,
                            ),
                            onChanged: (v) => l.units.text =
                                '${proposedUnits(l.item, int.tryParse(v) ?? 0)}',
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (l.item.medicationId != null)
                          Expanded(
                            child: TextField(
                              controller: l.units,
                              enabled: l.addToStock,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: l10n.rxUnitsToAdd,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (l.item.medicationId != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: l.addToStock,
                        title: Text(l10n.rxAddToStock),
                        onChanged: (v) => setState(() => l.addToStock = v),
                      ),
                  ],
                ),
              ),
            ),
          TextField(
            controller: _pharmacy,
            decoration: InputDecoration(labelText: l10n.rxPharmacy),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || _lines.isEmpty ? null : _save,
            child: Text(l10n.rxRedeem),
          ),
        ],
      ),
    );
  }
}
