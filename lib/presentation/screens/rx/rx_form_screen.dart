/// Medora - Add or edit a prescription.
///
/// Opened with a scan's [RxDraft], the form starts prefilled: every value
/// read from the text (not a barcode, see [RxDraft.fromBarcode]) carries the
/// `rxFromScan` hint, since the user has to check it. Saving then attaches
/// the scanned original to the prescription and links each item whose AIC
/// matches exactly one cabinet medication.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/attachment_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/attachment_picker.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

class RxFormScreen extends ConsumerStatefulWidget {
  const RxFormScreen({
    super.key,
    this.rxId,
    this.treatmentId,
    this.personId,
    this.draft,
    this.originalPath,
    this.originalName,
  });

  final String? rxId;
  final String? treatmentId;
  final String? personId;

  /// What a scan read, to prefill a new prescription with (add mode only).
  final RxDraft? draft;

  /// The scanned photo or PDF, attached to the prescription once it is
  /// saved. The caller owns the file and deletes it after this route pops.
  final String? originalPath;

  /// The original's file name as picked, when known; the attachment's name
  /// (and, for an image, the extension the import goes by).
  final String? originalName;

  @override
  ConsumerState<RxFormScreen> createState() => _RxFormScreenState();
}

/// One editable item row.
class _ItemDraft {
  _ItemDraft(
    this.id, {
    String description = '',
    int packs = 1,
    String? posology,
  }) : description = TextEditingController(text: description),
       packs = TextEditingController(text: '$packs'),
       posology = TextEditingController(text: posology ?? '');

  final String id;
  final TextEditingController description;
  final TextEditingController packs;
  final TextEditingController posology;
  String? medicationId;
  String? aic;
  bool nonSubstitutable = false;

  /// Read from a scan's text: shows the `rxFromScan` hint.
  bool fromScan = false;

  void dispose() {
    description.dispose();
    packs.dispose();
    posology.dispose();
  }
}

class _RxFormScreenState extends ConsumerState<RxFormScreen> {
  static const _uuid = Uuid();
  final _form = GlobalKey<FormState>();
  final _nre = TextEditingController();
  final _pin = TextEditingController();
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

  /// A scanned "valid for n days": the default validity is then the issue
  /// date plus these days, following issue-date edits, until one is picked.
  int? _validDays;
  String? _nreDuplicateHint;
  bool _saving = false;

  /// Set by a save refused for [_validBeforeIssued]; the error then shows
  /// until the dates are fixed.
  bool _showValidityError = false;

  /// The fields a scan filled from text rather than a barcode (see
  /// [_applyDraft]); each shows the `rxFromScan` hint.
  final _fromScan = <String>{};

  /// Set when [_load] fails, so [build] shows a static error state instead
  /// of an indeterminate spinner that would otherwise animate forever if
  /// [Navigator.maybePop] has nowhere to go (this is the only route).
  bool _loadFailed = false;

  /// White electronic prescriptions carry an NRBE and a PIN; the other
  /// kinds carry neither the PIN field nor (for a paper white
  /// prescription) any number at all.
  bool get _isWhiteKind =>
      _kind == RxKind.white || _kind == RxKind.whiteRepeatable;

  @override
  void initState() {
    super.initState();
    final now = ref.read(nowProvider)();
    _issuedOn = DateTime(now.year, now.month, now.day);
    _personId = widget.personId;
    final id = widget.rxId;
    if (id != null) {
      _load(id);
    } else if (widget.draft case final draft?) {
      _applyDraft(draft);
    }
  }

  /// Prefills the form from a scan. A printed validity date is kept as if
  /// picked, so a kind or issue-date change leaves it alone; one computed
  /// from "valid for n days" follows the issue date instead. Fields not
  /// named in [RxDraft.fromBarcode] were only recognised in the text and
  /// are marked for the `rxFromScan` hint.
  void _applyDraft(RxDraft draft) {
    void mark(String field, Object? value) {
      if (value != null && !draft.fromBarcode.contains(field)) {
        _fromScan.add(field);
      }
    }

    if (draft.kind case final kind?) _kind = kind;
    mark('kind', draft.kind);
    _nre.text = draft.nre ?? '';
    mark('nre', draft.nre);
    _pin.text = draft.pin ?? '';
    mark('pin', draft.pin);
    if (draft.issuedOn case final d?) {
      _issuedOn = DateTime(d.year, d.month, d.day);
    }
    mark('issuedOn', draft.issuedOn);
    if (draft.validDays case final days? when draft.issuedOn != null) {
      _validDays = days;
    } else if (draft.validUntil case final d?) {
      _validUntilPicked = DateTime(d.year, d.month, d.day);
    }
    mark('validUntil', draft.validUntil);
    _maxDispensings.text = draft.maxDispensings?.toString() ?? '';
    mark('maxDispensings', draft.maxDispensings);
    _exemption.text = draft.exemptionCode ?? '';
    mark('exemptionCode', draft.exemptionCode);
    _priority = draft.priority;
    mark('priority', draft.priority);
    _doctor.text = draft.doctor ?? '';
    mark('doctor', draft.doctor);
    for (final item in draft.items) {
      _items.add(
        _ItemDraft(
            _uuid.v4(),
            description: item.description,
            packs: item.packs,
            posology: item.posology,
          )
          ..aic = item.aic
          ..fromScan = true,
      );
    }
  }

  /// The `rxFromScan` hint for [field], or null when it was not read from
  /// a scan's text.
  String? _scanHint(AppLocalizations l10n, String field) =>
      _fromScan.contains(field) ? l10n.rxFromScan : null;

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
          _pin.text = r.pin ?? '';
          _doctor.text = r.doctor ?? '';
          _exemption.text = r.exemptionCode ?? '';
          _notes.text = r.notes ?? '';
          _maxDispensings.text = r.maxDispensings?.toString() ?? '';
          for (final i in r.items) {
            _items.add(
              _ItemDraft(
                  i.id,
                  description: i.description,
                  packs: i.packs,
                  posology: i.posology,
                )
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
    for (final c in [
      _nre,
      _pin,
      _doctor,
      _exemption,
      _notes,
      _maxDispensings,
    ]) {
      c.dispose();
    }
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  /// The number field still holds the stored prescription's number, under
  /// its stored kind: a kind switch makes the legacy bypass below re-check
  /// the number against the new kind's validator (and, for a white kind,
  /// the PIN rule) rather than keep waving it through unchanged.
  bool get _nreUnchanged {
    final existing = _existing;
    if (existing == null || existing.kind != _kind) return false;
    final stored = existing.nre;
    return stored != null && Nre.normalize(_nre.text) == Nre.normalize(stored);
  }

  DateTime? get _validUntil =>
      _validUntilPicked ??
      switch (_validDays) {
        final days? => DateTime(
          _issuedOn.year,
          _issuedOn.month,
          _issuedOn.day + days,
        ),
        null => RxValidity.defaultValidUntil(_kind, _issuedOn),
      };

  String? _text(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  /// True when the last valid day comes before the issue date: the issue
  /// date can be moved past a picked validity after the picker (whose first
  /// date is the issue date) was used, and a stored row can be so too.
  bool get _validBeforeIssued {
    final until = _validUntil;
    if (until == null) return false;
    return DateTime(
      until.year,
      until.month,
      until.day,
    ).isBefore(DateTime(_issuedOn.year, _issuedOn.month, _issuedOn.day));
  }

  Future<void> _save() async {
    final valid = _form.currentState!.validate();
    setState(() => _showValidityError = _validBeforeIssued);
    if (_saving || !valid || _showValidityError) return;
    setState(() => _saving = true);
    // A PopScope can't trap the user if something here throws: whatever
    // happens, `_saving` is reset in `finally` so the form is usable again
    // (and, with no scanned original, poppable) rather than stuck loading.
    try {
      final l10n = AppLocalizations.of(context);
      final nre = _text(_nre);
      final pin = _isWhiteKind ? _text(_pin) : null;
      // Read before any await: the saves below outlive a pop in between.
      final rxRepository = ref.read(rxRepositoryProvider);
      final linked = await _linkScannedItems();
      if (!mounted) return;
      final rx = Rx(
        id: _existing?.id ?? _uuid.v4(),
        userId: _existing?.userId,
        personId: _personId,
        treatmentId: _existing?.treatmentId ?? widget.treatmentId,
        kind: _kind,
        nre: nre == null ? null : Nre.normalize(nre),
        pin: pin == null ? null : Nre.normalize(pin),
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
                medicationId: i.medicationId ?? linked[i.id],
                aic: i.aic,
                description: i.description.text.trim(),
                packs: int.tryParse(i.packs.text.trim()) ?? 1,
                nonSubstitutable: i.nonSubstitutable,
                posology: _text(i.posology),
              ),
        ],
        closedOn: _existing?.closedOn,
        cancelled: _existing?.cancelled ?? false,
        notes: _text(_notes),
        createdAt: _existing?.createdAt,
        updatedAt: _existing?.updatedAt,
      );
      final result = await rxRepository.saveRx(rx);
      if (!mounted) return;
      if (result case Success(data: final saved)) {
        invalidateRx(ref);
        if (widget.originalPath case final original?) {
          await _attachOriginal(saved.id, original);
          if (!mounted) return;
        }
        // `pop`, not `maybePop`: unlike a system back gesture, an explicit
        // pop is not blocked by the PopScope below, so it does not need to
        // wait for `finally`'s reset of `_saving` to have rebuilt first.
        final navigator = Navigator.of(context);
        if (navigator.canPop()) navigator.pop();
        return;
      }
      result.when(
        success: (_) {},
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
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// For a scanned prescription: the cabinet medication each item with an
  /// AIC (and no link yet) matches, by item id — only where exactly one
  /// **active** medication's barcode equals it, never a guess between
  /// several and never an archived pack (an old, discontinued one can share
  /// an AIC with the active replacement). Linking is a convenience with no
  /// prompt, so a failed medication read just links nothing (the
  /// prescription saves regardless).
  Future<Map<String, String>> _linkScannedItems() async {
    if (widget.draft == null) return const {};
    final pending = [
      for (final i in _items)
        if (i.aic != null && i.medicationId == null) i,
    ];
    if (pending.isEmpty) return const {};
    final result = await ref
        .read(medicationRepositoryProvider)
        .getMedications();
    final medications = result.dataOrNull ?? const <Medication>[];
    return {
      for (final item in pending)
        if (medications
                .where((m) => m.barcode == item.aic && !m.isArchived)
                .toList()
            case [final only])
          item.id: only.id,
    };
  }

  /// Attaches the scanned original to the just-saved prescription [rxId].
  /// The prescription stays saved whatever happens here; a refused or
  /// failed attach is only reported. Everything it needs from `ref` is read
  /// up front, so the attach still completes if the form is gone meanwhile.
  Future<void> _attachOriginal(String rxId, String originalPath) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final importer = ref.read(attachmentImportProvider);
    final attachments = ref.read(attachmentRepositoryProvider);
    final transfer = ref.read(attachmentTransferProvider);
    void report(String message) =>
        messenger.showSnackBar(SnackBar(content: Text(message)));

    final ImportResult imported;
    try {
      imported = await importer(
        originalPath,
        originalName: widget.originalName ?? path.basename(originalPath),
      );
    } catch (_) {
      report(l10n.rxAttachmentUnreadable);
      return;
    }
    switch (imported) {
      case ImportRefused(:final reason):
        report(switch (reason) {
          ImportRefusal.tooLarge => l10n.rxAttachmentTooLarge,
          ImportRefusal.unsupported => l10n.rxAttachmentUnsupported,
          ImportRefusal.unreadable => l10n.rxAttachmentUnreadable,
        });
      case Imported():
        final added = await attachments.add(
          AttachmentOwnerKind.rx,
          rxId,
          imported,
        );
        if (added.isFailure) {
          report(l10n.genericError);
          return;
        }
        if (mounted) {
          ref.invalidate(attachmentsForOwnerProvider);
          ref.invalidate(attachmentCountsProvider);
        }
        unawaited(transfer.run());
    }
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
    // No leaving mid-save: a scanned original is still being attached (and
    // the caller deletes it once this route pops).
    return PopScope(
      canPop: !_saving,
      child: _buildForm(context, l10n, persons, person, personDropdownValue),
    );
  }

  Widget _buildForm(
    BuildContext context,
    AppLocalizations l10n,
    List<Person> persons,
    Person? person,
    String? personDropdownValue,
  ) {
    final now = ref.watch(nowProvider)();
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
              decoration: InputDecoration(
                labelText: l10n.rxKind,
                helperText: _scanHint(l10n, 'kind'),
              ),
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
                labelText: _isWhiteKind ? l10n.rxNrbe : l10n.rxNre,
                helperText: _nreDuplicateHint ?? _scanHint(l10n, 'nre'),
              ),
              validator: (v) {
                final raw = (v ?? '').trim();
                // A stored number from before the NRE/NRBE shapes were
                // enforced stays valid until it is changed.
                if (raw.isEmpty || _nreUnchanged) return null;
                if (_isWhiteKind) {
                  return Nre.isNrbe(raw) ? null : l10n.rxNrbeInvalid;
                }
                return Nre.isValid(raw) ? null : l10n.rxNreInvalid;
              },
              onChanged: (_) {
                if (_nreDuplicateHint != null) {
                  setState(() => _nreDuplicateHint = null);
                }
              },
            ),
            if (_isWhiteKind) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('rx_pin'),
                controller: _pin,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: l10n.rxPin,
                  hintText: l10n.rxPinHint,
                  helperText: _scanHint(l10n, 'pin'),
                ),
                validator: (v) {
                  final raw = (v ?? '').trim();
                  final nreEntered = _text(_nre) != null && !_nreUnchanged;
                  if (raw.isEmpty) return nreEntered ? l10n.required : null;
                  return Nre.isPin(raw) ? null : l10n.rxPinInvalid;
                },
              ),
            ],
            const SizedBox(height: 12),
            DatePickerField(
              label: l10n.rxIssuedOn,
              icon: Icons.event_outlined,
              date: _issuedOn,
              now: now,
              helperText: _scanHint(l10n, 'issuedOn'),
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
              helperText: _scanHint(l10n, 'validUntil'),
              errorText: _showValidityError && _validBeforeIssued
                  ? l10n.rxValidBeforeIssued
                  : null,
              onDateSelected: (d) => setState(() => _validUntilPicked = d),
            ),
            if (_kind == RxKind.referral) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<RxPriority?>(
                initialValue: _priority,
                decoration: InputDecoration(
                  labelText: l10n.rxPriority,
                  helperText: _scanHint(l10n, 'priority'),
                ),
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
                  helperText: _scanHint(l10n, 'maxDispensings'),
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
                helperText: _scanHint(l10n, 'doctor'),
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
                helperText: _scanHint(l10n, 'exemptionCode'),
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
                      helperText: item.fromScan ? l10n.rxFromScan : null,
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
            TextFormField(
              key: Key('rx_item_posology_$index'),
              controller: item.posology,
              decoration: InputDecoration(labelText: l10n.rxPosology),
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
