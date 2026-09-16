/// Medora - Add/Edit Treatment Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
import 'package:medora/presentation/widgets/forms/tag_input_field.dart';
import 'package:uuid/uuid.dart';

class AddTreatmentScreen extends ConsumerStatefulWidget {
  const AddTreatmentScreen({super.key, this.treatmentId});

  final String? treatmentId;

  @override
  ConsumerState<AddTreatmentScreen> createState() => _AddTreatmentScreenState();
}

class _AddTreatmentScreenState extends ConsumerState<AddTreatmentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  late final TextEditingController _nameController;
  late final TextEditingController _notesController;

  List<String> _patientTags = [];
  List<String> _symptomTags = [];
  late DateTime _startDate;
  DateTime? _endDate;
  bool _isLoading = false;
  bool _isEditMode = false;
  Treatment? _existingTreatment;

  DateTime? _sickLeaveFrom;
  DateTime? _sickLeaveTo;
  late final TextEditingController _sickLeaveRefController;
  late final TextEditingController _doctorController;

  /// Two-way synced with the section's [FormSection.controller]: opens the
  /// section when an edited treatment already has sick-leave data, and
  /// force-opens it to reveal a validation error.
  final _sickLeaveExpanded = ValueNotifier<bool>(false);
  String? _sickLeaveError;

  @override
  void initState() {
    super.initState();
    _startDate = ref.read(nowProvider)();
    _nameController = TextEditingController();
    _notesController = TextEditingController();
    _sickLeaveRefController = TextEditingController();
    _doctorController = TextEditingController();
    _isEditMode = widget.treatmentId != null;
    if (_isEditMode) {
      _loadExistingTreatment();
    }
  }

  Future<void> _loadExistingTreatment() async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.getTreatmentById(widget.treatmentId!);
    result.when(
      success: (t) {
        setState(() {
          _existingTreatment = t;
          _nameController.text = t.name;
          _patientTags = List.of(t.patientTags);
          _symptomTags = List.of(t.symptomTags);
          _startDate = t.startDate;
          _endDate = t.endDate;
          _notesController.text = t.notes ?? '';
          _sickLeaveFrom = t.sickLeaveFrom;
          _sickLeaveTo = t.sickLeaveTo;
          _sickLeaveRefController.text = t.sickLeaveRef ?? '';
          _doctorController.text = t.doctor ?? '';
        });
        _sickLeaveExpanded.value =
            t.sickLeaveFrom != null ||
            t.sickLeaveTo != null ||
            t.sickLeaveRef != null ||
            t.doctor != null;
      },
      failure: (msg) {
        if (mounted) {
          final l10n = AppLocalizations.of(context);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(msg))));
        }
      },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _sickLeaveRefController.dispose();
    _doctorController.dispose();
    _sickLeaveExpanded.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditMode ? l10n.editTreatment : l10n.newTreatmentTitle),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Name
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.treatmentNameLabel,
                prefixIcon: const Icon(Icons.healing),
                hintText: l10n.treatmentNameHint,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.pleaseEnterTreatmentName;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Patient Tags
            TagInputField(
              label: l10n.treatmentPatientTags,
              icon: Icons.person,
              hintText: l10n.patientNameHint,
              tags: _patientTags,
              onChanged: (tags) => setState(() => _patientTags = tags),
              isUserTag: true,
            ),
            const SizedBox(height: 16),

            // Symptom Tags
            TagInputField(
              label: l10n.treatmentSymptomTags,
              icon: Icons.sick,
              hintText: l10n.symptomsHint,
              tags: _symptomTags,
              onChanged: (tags) => setState(() => _symptomTags = tags),
            ),
            const SizedBox(height: 16),

            // Start Date
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _startDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _startDate = picked);
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: l10n.startDateLabel,
                  prefixIcon: const Icon(Icons.calendar_today),
                ),
                child: Text(
                  '${_startDate.year}-${_startDate.month.toString().padLeft(2, '0')}-${_startDate.day.toString().padLeft(2, '0')}',
                ),
              ),
            ),
            const SizedBox(height: 16),

            // End Date (optional)
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate:
                      _endDate ?? _startDate.add(const Duration(days: 7)),
                  firstDate: _startDate,
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _endDate = picked);
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: l10n.endDateLabel,
                  prefixIcon: const Icon(Icons.event),
                  suffixIcon: _endDate != null
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() => _endDate = null),
                        )
                      : null,
                ),
                child: Text(
                  _endDate != null
                      ? '${_endDate!.year}-${_endDate!.month.toString().padLeft(2, '0')}-${_endDate!.day.toString().padLeft(2, '0')}'
                      : l10n.selectEndDate,
                  style: TextStyle(
                    color: _endDate != null ? null : context.colors.outline,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Notes
            TextFormField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.notes,
                prefixIcon: const Icon(Icons.notes),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),

            // Sick leave (Krankenstand): collapsed by default, so an
            // ordinary therapy still shows the form it always had. Rebuilt
            // on expand/collapse: the summary may show the text fields, which
            // can only change while the section is open.
            ListenableBuilder(
              listenable: _sickLeaveExpanded,
              builder: (context, _) => FormSection(
                key: const Key('sickLeaveSection'),
                title: l10n.sickLeave,
                icon: Icons.work_off,
                initiallyExpanded: false,
                controller: _sickLeaveExpanded,
                summary: _sickLeaveSummary(l10n),
                children: [
                  DatePickerField(
                    key: const Key('sickLeaveFromField'),
                    label: l10n.sickLeaveFrom,
                    icon: Icons.event_busy,
                    date: _sickLeaveFrom,
                    now: now,
                    lastDate: _sickLeaveTo,
                    onDateSelected: (d) => setState(() {
                      _sickLeaveFrom = d;
                      // With no start, an end date means nothing; keeping it
                      // would block the save with an error about this field.
                      if (d == null) _sickLeaveTo = null;
                      _sickLeaveError = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  DatePickerField(
                    key: const Key('sickLeaveToField'),
                    label: l10n.sickLeaveTo,
                    icon: Icons.event_available,
                    date: _sickLeaveTo,
                    now: now,
                    firstDate: _sickLeaveFrom,
                    onDateSelected: (d) => setState(() {
                      _sickLeaveTo = d;
                      _sickLeaveError = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('sickLeaveRefField'),
                    controller: _sickLeaveRefController,
                    decoration: InputDecoration(
                      labelText: l10n.sickLeaveRef,
                      prefixIcon: const Icon(Icons.confirmation_number),
                      hintText: l10n.sickLeaveRefHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('doctorField'),
                    controller: _doctorController,
                    decoration: InputDecoration(
                      labelText: l10n.doctorLabel,
                      prefixIcon: const Icon(Icons.medical_services),
                      hintText: l10n.doctorHint,
                    ),
                  ),
                  if (_sickLeaveError != null) ...[
                    const SizedBox(height: 8),
                    // A live region, so a screen reader announces why Save
                    // did nothing.
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _sickLeaveError!,
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Save Button
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _saveTreatment,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Text(
                        _isEditMode
                            ? l10n.updateTreatment
                            : l10n.createTreatment,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The collapsed section's one-line summary: the range once a start date
  /// is set, else the doctor, else the certificate number, otherwise nothing
  /// (FormSection hides a null summary), so a filled section never looks
  /// empty.
  String? _sickLeaveSummary(AppLocalizations l10n) {
    final from = _sickLeaveFrom;
    if (from != null) {
      return '${from.formatted} – ${_sickLeaveTo.formattedOr(l10n.ongoing)}';
    }
    return _textOrNull(_doctorController) ??
        _textOrNull(_sickLeaveRefController);
  }

  /// The error to show, or null when the section is consistent. An end
  /// without a start, or an end before its start, are both rejected; each
  /// message names the sick-leave fields as they are labelled, so it cannot
  /// be read as being about the treatment's own start and end dates.
  String? _validateSickLeave(AppLocalizations l10n) {
    final to = _sickLeaveTo;
    if (to == null) return null;
    final from = _sickLeaveFrom;
    if (from == null) return l10n.sickLeaveFromMissing(l10n.sickLeaveFrom);
    if (to.isBefore(from)) {
      return l10n.sickLeaveToBeforeFrom(l10n.sickLeaveTo, l10n.sickLeaveFrom);
    }
    return null;
  }

  /// Trimmed text, or null when nothing but whitespace was entered.
  static String? _textOrNull(TextEditingController c) {
    final text = c.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _saveTreatment() async {
    if (!_formKey.currentState!.validate()) return;

    final l10n = AppLocalizations.of(context);
    final sickLeaveError = _validateSickLeave(l10n);
    if (sickLeaveError != null) {
      setState(() => _sickLeaveError = sickLeaveError);
      _sickLeaveExpanded.value = true;
      return;
    }

    setState(() => _isLoading = true);

    final treatment = Treatment(
      id: _existingTreatment?.id ?? _uuid.v4(),
      userId: SupabaseConfig.currentUserId,
      name: _nameController.text.trim(),
      patientTags: _patientTags,
      symptomTags: _symptomTags,
      startDate: _startDate,
      endDate: _endDate,
      isActive: _existingTreatment?.isActive ?? true,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      // The constructor, not copyWith, is what lets a cleared field reach
      // the database as null.
      sickLeaveFrom: _sickLeaveFrom,
      sickLeaveTo: _sickLeaveTo,
      sickLeaveRef: _textOrNull(_sickLeaveRefController),
      doctor: _textOrNull(_doctorController),
    );

    try {
      if (_isEditMode) {
        await ref
            .read(treatmentListProvider.notifier)
            .updateTreatment(treatment);
      } else {
        await ref.read(treatmentListProvider.notifier).addTreatment(treatment);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditMode
                  ? l10n.treatmentUpdatedSuccessfully
                  : l10n.treatmentCreatedSuccessfully,
            ),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
