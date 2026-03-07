/// Medora - Add/Edit Treatment Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:uuid/uuid.dart';

class AddTreatmentScreen extends ConsumerStatefulWidget {
  const AddTreatmentScreen({super.key, this.treatmentId});

  final String? treatmentId;

  @override
  ConsumerState<AddTreatmentScreen> createState() =>
      _AddTreatmentScreenState();
}

class _AddTreatmentScreenState extends ConsumerState<AddTreatmentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  late final TextEditingController _nameController;
  late final TextEditingController _notesController;

  List<String> _patientTags = [];
  List<String> _symptomTags = [];
  DateTime _startDate = DateTime.now();
  DateTime? _endDate;
  bool _isLoading = false;
  bool _isEditMode = false;
  Treatment? _existingTreatment;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _notesController = TextEditingController();
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
        });
      },
      failure: (msg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $msg')),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
            _TagInputField(
              label: l10n.treatmentPatientTags,
              icon: Icons.person,
              hintText: l10n.patientNameHint,
              tags: _patientTags,
              onChanged: (tags) => setState(() => _patientTags = tags),
            ),
            const SizedBox(height: 16),

            // Symptom Tags
            _TagInputField(
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
                    color: _endDate != null ? null : Colors.grey[500],
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
            const SizedBox(height: 32),

            // Save Button
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _saveTreatment,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Text(_isEditMode
                        ? l10n.updateTreatment
                        : l10n.createTreatment),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveTreatment() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final l10n = AppLocalizations.of(context);

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
    );

    try {
      if (_isEditMode) {
        await ref
            .read(treatmentListProvider.notifier)
            .updateTreatment(treatment);
      } else {
        await ref
            .read(treatmentListProvider.notifier)
            .addTreatment(treatment);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEditMode
                ? l10n.treatmentUpdatedSuccessfully
                : l10n.treatmentCreatedSuccessfully),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// Reusable tag input field for treatment screen.
class _TagInputField extends StatefulWidget {
  const _TagInputField({
    required this.label,
    required this.icon,
    required this.tags,
    required this.onChanged,
    this.hintText,
  });

  final String label;
  final IconData icon;
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final String? hintText;

  @override
  State<_TagInputField> createState() => _TagInputFieldState();
}

class _TagInputFieldState extends State<_TagInputField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  void _addTag(String text) {
    final tag = text.trim();
    if (tag.isNotEmpty && !widget.tags.contains(tag)) {
      widget.onChanged([...widget.tags, tag]);
    }
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: widget.tags.map((tag) {
                return Chip(
                  label: Text(tag, style: const TextStyle(fontSize: 13)),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () {
                    widget.onChanged(
                        widget.tags.where((t) => t != tag).toList());
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: Icon(widget.icon),
            hintText: widget.hintText ?? l10n.addTag,
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _addTag(_controller.text),
            ),
          ),
          onSubmitted: (value) {
            _addTag(value);
            _focusNode.requestFocus();
          },
        ),
      ],
    );
  }
}
