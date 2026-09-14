/// Medora - Shared quantity unit dropdown.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Dropdown for picking a [AppConstants.quantityUnitKeys] value, with
/// localized labels via [AppConstants.unitLabel].
class UnitDropdown extends StatelessWidget {
  const UnitDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.decoration,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String? label;
  final InputDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DropdownButtonFormField<String>(
      key: ValueKey('unit_$value'),
      initialValue: value,
      decoration: decoration ?? InputDecoration(labelText: label),
      items: AppConstants.quantityUnitKeys.map((key) {
        return DropdownMenuItem(
          value: key,
          child: Text(AppConstants.unitLabel(l10n, key)),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}
