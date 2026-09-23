/// Medora - Add or edit a prescription.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:uuid/uuid.dart';

class RxFormScreen extends ConsumerStatefulWidget {
  const RxFormScreen({super.key, this.rxId, this.treatmentId, this.personId});

  final String? rxId;
  final String? treatmentId;
  final String? personId;

  @override
  ConsumerState<RxFormScreen> createState() => _RxFormScreenState();
}

/// One editable item row.
class _ItemDraft {
  _ItemDraft(this.id, {String description = '', int packs = 1})
    : description = TextEditingController(text: description),
      packs = TextEditingController(text: '$packs');

  final String id;
  final TextEditingController description;
  final TextEditingController packs;
  String? medicationId;
  String? aic;
  bool nonSubstitutable = false;

  void dispose() {
    description.dispose();
    packs.dispose();
  }
}

class _RxFormScreenState extends ConsumerState<RxFormScreen> {
  static const _uuid = Uuid();
  final _form = GlobalKey<FormState>();
  final _nre = TextEditingController();
  final _doctor = TextEditingController();
  final _exemption = TextEditingController();
  final _notes = TextEditingController();
  final _maxDispensings = TextEditingController();
  final _items = <_ItemDraft>[];

  Rx? _existing;
  RxKind _kind = RxKind.ssn;
  RxPriority? _priority;
  String? _personId;
  late DateTime _issuedOn;

  /// Null until the user (or, in edit mode, the stored prescription) picks
  /// one; then it is kept as-is regardless of kind or issue-date changes,
  /// which only drive the default below.
  DateTime? _validUntilPicked;
  String? _nreDuplicateHint;
  bool _saving = false;

  /// Set when [_load] fails, so [build] shows a static error state instead
  /// of an indeterminate spinner that would otherwise animate forever if
  /// [Navigator.maybePop] has nowhere to go (this is the only route).
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    final now = ref.read(nowProvider)();
    _issuedOn = DateTime(now.year, now.month, now.day);
    _personId = widget.personId;
    final id = widget.rxId;
    if (id != null) _load(id);
  }

  /// Loads the existing prescription before the form is shown at all (see
  /// [build]), so there is never a window where the user can type into
  /// fields the load is about to fill. A failure (e.g. a deleted or
  /// unreachable rx) is reported and the screen pops itself, rather than
  /// leaving the caller to save an empty/default rx over the real one.
  ///
  /// Goes straight to the repository rather than through [rxByIdProvider]:
  /// that provider has no other watcher for this specific id while the form
  /// is loading, so it is eligible for disposal mid-flight, which would
  /// turn a real, in-progress load into a spurious failure.
  Future<void> _load(String id) async {
    final result = await ref.read(rxRepositoryProvider).getById(id);
    if (!mounted) return;
    result.when(
      success: (withDispensings) {
        final r = withDispensings.rx;
        setState(() {
          _existing = r;
          _kind = r.kind;
          _priority = r.priority;
          _personId = r.personId;
          _issuedOn = r.issuedOn;
          _validUntilPicked = r.validUntil;
          _nre.text = r.nre ?? '';
          _doctor.text = r.doctor ?? '';
          _exemption.text = r.exemptionCode ?? '';
          _notes.text = r.notes ?? '';
          _maxDispensings.text = r.maxDispensings?.toString() ?? '';
          for (final i in r.items) {
            _items.add(
              _ItemDraft(i.id, description: i.description, packs: i.packs)
                ..medicationId = i.medicationId
                ..aic = i.aic
                ..nonSubstitutable = i.nonSubstitutable,
            );
          }
        });
      },
      failure: (_) {
        setState(() => _loadFailed = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).genericError)),
        );
        Navigator.of(context).maybePop();
      },
    );
  }

  @override
  void dispose() {
    for (final c in [_nre, _doctor, _exemption, _notes, _maxDispensings]) {
      c.dispose();
    }
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  DateTime? get _validUntil =>
      _validUntilPicked ?? RxValidity.defaultValidUntil(_kind, _issuedOn);

  String? _text(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context);
    final nre = _text(_nre);
    final rx = Rx(
      id: _existing?.id ?? _uuid.v4(),
      userId: _existing?.userId,
      personId: _personId,
      treatmentId: _existing?.treatmentId ?? widget.treatmentId,
      kind: _kind,
      nre: nre == null ? null : Nre.normalize(nre),
      issuedOn: _issuedOn,
      validUntil: _validUntil,
      doctor: _text(_doctor),
      exemptionCode: _text(_exemption)?.toUpperCase(),
      priority: _kind == RxKind.referral ? _priority : null,
      maxDispensings: _kind == RxKind.whiteRepeatable
          ? int.tryParse(_maxDispensings.text.trim()) ??
                RxValidity.defaultMaxDispensings(_kind)
          : null,
      items: [
        for (final i in _items)
          if (i.description.text.trim().isNotEmpty)
            RxItem(
              id: i.id,
              medicationId: i.medicationId,
              aic: i.aic,
              description: i.description.text.trim(),
              packs: int.tryParse(i.packs.text.trim()) ?? 1,
              nonSubstitutable: i.nonSubstitutable,
            ),
      ],
      closedOn: _existing?.closedOn,
      cancelled: _existing?.cancelled ?? false,
      notes: _text(_notes),
      createdAt: _existing?.createdAt,
      updatedAt: _existing?.updatedAt,
    );
    final result = await ref.read(rxRepositoryProvider).saveRx(rx);
    if (!mounted) return;
    setState(() => _saving = false);
    result.when(
      success: (_) {
        invalidateRx(ref);
        Navigator.of(context).maybePop();
      },
      failure: (message) {
        if (message.startsWith(duplicateNrePrefix)) {
          final existing = message.substring(duplicateNrePrefix.length);
          setState(() => _nreDuplicateHint = l10n.rxNreDuplicateHint);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.rxNreDuplicate),
              action: SnackBarAction(
                label: l10n.rxOpenExisting,
                onPressed: () => context.push(
                  AppRoutes.rxDetail.replaceFirst(':id', existing),
                ),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.genericError)));
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Watched unconditionally (even while the loading gate below is up) so
    // the persons list starts loading in parallel with the rx itself,
    // rather than only once the rx has already arrived.
    final persons = ref.watch(personsProvider).value ?? const <Person>[];
    // Edit mode: nothing is shown (no fields, no Save) until the load
    // resolves, so there is never a live form a stray keystroke or an early
    // tap of Save could act on before the real data has arrived. A failed
    // load reports itself and pops (see _load) instead of landing here.
    if (widget.rxId != null && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.rxEdit)),
        body: Center(
          child: _loadFailed
              // Static, not animated: nothing left to wait for once the
              // load has failed and (usually) already popped this screen.
              ? const Icon(Icons.error_outline, size: 48)
              : const CircularProgressIndicator(),
        ),
      );
    }
    final now = ref.watch(nowProvider)();
    final person = persons.where((p) => p.id == _personId).firstOrNull;
    // The persons list can still be behind _personId for a frame right
    // after the rx load resolves (two independent providers); fall back to
    // "no person" in the dropdown for that frame rather than passing it a
    // value none of its current items have. _personId itself is untouched,
    // so saving is unaffected and the dropdown corrects itself once persons
    // catches up.
    final personDropdownValue = persons.any((p) => p.id == _personId)
        ? _personId
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(_existing == null ? l10n.rxNew : l10n.rxEdit)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String?>(
              initialValue: personDropdownValue,
              decoration: InputDecoration(labelText: l10n.rxPerson),
              items: [
                DropdownMenuItem(child: Text(l10n.rxNoPerson)),
                for (final p in persons)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (id) => setState(() => _personId = id),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RxKind>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.rxKind),
              items: [
                for (final k in RxKind.values)
                  DropdownMenuItem(value: k, child: Text(rxKindLabel(l10n, k))),
              ],
              // _validUntilPicked is deliberately left untouched: a picked
              // (or, in edit mode, stored) validity survives a kind change;
              // only the unpicked default (the _validUntil getter) follows
              // it.
              onChanged: (k) => setState(() => _kind = k ?? RxKind.ssn),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('rx_nre'),
              controller: _nre,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.rxNre,
                helperText: _nreDuplicateHint,
              ),
              validator: (v) {
                final raw = (v ?? '').trim();
                if (raw.isEmpty) return null;
                return Nre.isValid(raw) ? null : l10n.rxNreInvalid;
              },
              onChanged: (_) {
                if (_nreDuplicateHint != null) {
                  setState(() => _nreDuplicateHint = null);
                }
              },
            ),
            const SizedBox(height: 12),
            DatePickerField(
              label: l10n.rxIssuedOn,
              icon: Icons.event_outlined,
              date: _issuedOn,
              now: now,
              // Same as the kind change above: only the default follows.
              onDateSelected: (d) => setState(() {
                if (d != null) _issuedOn = d;
              }),
            ),
            const SizedBox(height: 12),
            DatePickerField(
              label: l10n.rxValidUntil,
              icon: Icons.event_available_outlined,
              date: _validUntil,
              now: now,
              firstDate: _issuedOn,
              onDateSelected: (d) => setState(() => _validUntilPicked = d),
            ),
            if (_kind == RxKind.referral) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<RxPriority?>(
                initialValue: _priority,
                decoration: InputDecoration(labelText: l10n.rxPriority),
                items: [
                  const DropdownMenuItem(child: Text('–')), // l10n-exempt
                  for (final p in RxPriority.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(rxPriorityLabel(l10n, p)),
                    ),
                ],
                onChanged: (p) => setState(() => _priority = p),
              ),
            ],
            if (_kind == RxKind.whiteRepeatable) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _maxDispensings,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.rxMaxDispensings,
                  hintText: '${RxValidity.defaultMaxDispensings(_kind)}',
                ),
                validator: (v) {
                  final raw = (v ?? '').trim();
                  if (raw.isEmpty) return null;
                  final n = int.tryParse(raw);
                  return n == null || n < 1 ? l10n.required : null;
                },
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _doctor,
              decoration: InputDecoration(
                labelText: l10n.doctorLabel,
                hintText: l10n.doctorHint,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _exemption,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.rxExemption,
                // The person's codes, as a hint: which one applies is the
                // doctor's call and printed on the prescription.
                hintText: person?.exemptions.join(', '),
              ),
            ),
            const SizedBox(height: 20),
            Text(l10n.rxItems, style: Theme.of(context).textTheme.titleSmall),
            for (final (index, item) in _items.indexed)
              _ItemRow(
                index: index,
                item: item,
                onRemove: () =>
                    setState(() => _items.removeAt(index).dispose()),
                onChanged: () => setState(() {}),
              ),
            TextButton.icon(
              key: const Key('rx_add_item'),
              onPressed: () =>
                  setState(() => _items.add(_ItemDraft(_uuid.v4()))),
              icon: const Icon(Icons.add),
              label: Text(l10n.rxAddItem),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.notes),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('rx_save'),
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.index,
    required this.item,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _ItemDraft item;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('rx_item_description_$index'),
                    controller: item.description,
                    decoration: InputDecoration(
                      labelText: l10n.rxItemDescription,
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  child: TextFormField(
                    key: Key('rx_item_packs_$index'),
                    controller: item.packs,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l10n.rxItemPacks),
                    validator: (v) {
                      // A row with no description is dropped on save (see
                      // RxFormScreen._save), so its packs value is never
                      // used and should not block the form.
                      if (item.description.text.trim().isEmpty) return null;
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 ? l10n.required : null;
                    },
                    onChanged: (_) => onChanged(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.delete,
                  onPressed: onRemove,
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: item.nonSubstitutable,
              title: Text(l10n.rxNonSubstitutable),
              onChanged: (v) {
                item.nonSubstitutable = v ?? false;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}
