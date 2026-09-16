/// Medora - Add/Edit Medication: the Details section.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
import 'package:medora/presentation/widgets/forms/tag_input_field.dart';

/// The collapsible "Details" section: description, the three tag fields,
/// category, manufacturer, ATC code, the optional [photo] section and notes.
///
/// The form state stays with the screen: this takes the controllers it
/// draws and reports every edit back through a callback.
class MedicationDetailsSection extends StatelessWidget {
  const MedicationDetailsSection({
    super.key,
    required this.descriptionController,
    required this.manufacturerController,
    required this.atcCodeController,
    required this.notesController,
    required this.expanded,
    required this.activeIngredients,
    required this.onActiveIngredientsChanged,
    required this.symptoms,
    required this.onSymptomsChanged,
    required this.patientTags,
    required this.onPatientTagsChanged,
    required this.category,
    required this.onCategoryChanged,
    required this.photo,
  });

  final TextEditingController descriptionController;
  final TextEditingController manufacturerController;
  final TextEditingController atcCodeController;
  final TextEditingController notesController;

  /// Two-way expansion, owned by the screen (see [FormSection.controller]).
  final ValueNotifier<bool> expanded;

  final List<String> activeIngredients;
  final ValueChanged<List<String>> onActiveIngredientsChanged;
  final List<String> symptoms;
  final ValueChanged<List<String>> onSymptomsChanged;
  final List<String> patientTags;
  final ValueChanged<List<String>> onPatientTagsChanged;
  final String? category;
  final ValueChanged<String?> onCategoryChanged;

  /// The photo picker, or null where photos are unavailable (web).
  final Widget? photo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FormSection(
      title: l10n.sectionDetails,
      icon: Icons.notes,
      initiallyExpanded: false,
      controller: expanded,
      children: [
        TextFormField(
          controller: descriptionController,
          decoration: InputDecoration(
            labelText: l10n.medicationDescription,
            prefixIcon: const Icon(Icons.description),
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 16),
        TagInputField(
          label: l10n.activeIngredients,
          icon: Icons.science,
          tags: activeIngredients,
          onChanged: onActiveIngredientsChanged,
        ),
        const SizedBox(height: 16),
        TagInputField(
          label: l10n.symptomsField,
          icon: Icons.local_hospital,
          tags: symptoms,
          onChanged: onSymptomsChanged,
        ),
        const SizedBox(height: 16),
        TagInputField(
          label: l10n.patientTagsField,
          icon: Icons.person,
          tags: patientTags,
          onChanged: onPatientTagsChanged,
          isUserTag: true,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey('cat_$category'),
          initialValue: category,
          decoration: InputDecoration(
            labelText: l10n.category,
            prefixIcon: const Icon(Icons.category),
          ),
          items: AppConstants.medicationCategoryKeys.map((key) {
            return DropdownMenuItem(
              value: key,
              child: Text(AppConstants.categoryLabel(l10n, key)),
            );
          }).toList(),
          onChanged: onCategoryChanged,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: manufacturerController,
          decoration: InputDecoration(
            labelText: l10n.manufacturerLabel,
            prefixIcon: const Icon(Icons.factory),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: atcCodeController,
          decoration: InputDecoration(
            labelText: l10n.atcCodeLabel,
            prefixIcon: const Icon(Icons.code),
          ),
          textCapitalization: TextCapitalization.characters,
        ),
        if (photo != null) ...[const SizedBox(height: 16), photo!],
        const SizedBox(height: 16),
        TextFormField(
          controller: notesController,
          decoration: InputDecoration(
            labelText: l10n.notes,
            prefixIcon: const Icon(Icons.notes),
          ),
          maxLines: 3,
        ),
      ],
    );
  }
}
