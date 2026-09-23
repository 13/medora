/// Medora - Add or edit a person (name, tax code, exemptions).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/rx/tax_code.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:uuid/uuid.dart';

class PersonFormScreen extends ConsumerStatefulWidget {
  const PersonFormScreen({super.key, this.personId});

  final String? personId;

  @override
  ConsumerState<PersonFormScreen> createState() => _PersonFormScreenState();
}

class _PersonFormScreenState extends ConsumerState<PersonFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _taxCode = TextEditingController();
  final _exemptions = TextEditingController();
  final _notes = TextEditingController();
  Person? _existing;
  bool _saving = false;

  /// True once the user has typed into any field. Guards [_load] from
  /// overwriting input that was entered while the async load was in flight.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final id = widget.personId;
    if (id != null) _load(id);
  }

  Future<void> _load(String id) async {
    final persons = await ref.read(personsProvider.future);
    final p = persons.where((p) => p.id == id).firstOrNull;
    if (p == null || !mounted) return;
    setState(() {
      // _existing is set regardless, so saving still updates this row; the
      // controllers are only filled if the user has not started typing.
      _existing = p;
      if (!_dirty) {
        _name.text = p.name;
        _taxCode.text = p.taxCode ?? '';
        _exemptions.text = p.exemptions.join(', ');
        _notes.text = p.notes ?? '';
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _taxCode.dispose();
    _exemptions.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// "e01, 048 ;E02" → ["E01", "048", "E02"].
  static List<String> _parseExemptions(String raw) => [
    for (final part in raw.split(RegExp(r'[,;\s]+')))
      if (part.trim().isNotEmpty) part.trim().toUpperCase(),
  ];

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final taxCode = _taxCode.text.trim();
    final notes = _notes.text.trim();
    final person = Person(
      id: _existing?.id ?? const Uuid().v4(),
      userId: _existing?.userId,
      name: _name.text.trim(),
      taxCode: taxCode.isEmpty ? null : TaxCode.normalize(taxCode),
      exemptions: _parseExemptions(_exemptions.text),
      notes: notes.isEmpty ? null : notes,
      createdAt: _existing?.createdAt,
      updatedAt: _existing?.updatedAt,
    );
    final result = await ref.read(personRepositoryProvider).savePerson(person);
    if (!mounted) return;
    setState(() => _saving = false);
    result.when(
      success: (_) {
        ref.invalidate(personsProvider);
        Navigator.of(context).maybePop();
      },
      failure: (_) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).genericError)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? l10n.personNew : l10n.personEdit),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('person_name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: l10n.name),
              validator: (v) => (v ?? '').trim().isEmpty ? l10n.required : null,
              onChanged: (_) => _dirty = true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('person_tax_code'),
              controller: _taxCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l10n.rxTaxCode),
              validator: (v) {
                final raw = (v ?? '').trim();
                if (raw.isEmpty) return null;
                return TaxCode.isValid(raw) ? null : l10n.rxTaxCodeInvalid;
              },
              onChanged: (_) => _dirty = true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('person_exemptions'),
              controller: _exemptions,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.personExemptions,
                hintText: l10n.personExemptionsHint,
              ),
              onChanged: (_) => _dirty = true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.notes),
              onChanged: (_) => _dirty = true,
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('person_save'),
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}
