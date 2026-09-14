/// Medora - Shared date picker form field.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Reusable date picker styled as a form field. Shows a locale-aware
/// formatted date, or [AppLocalizations.selectDate] when unset, and a
/// clear button once a date is picked.
class DatePickerField extends StatelessWidget {
  const DatePickerField({
    super.key,
    required this.label,
    required this.icon,
    required this.date,
    required this.onDateSelected,
    this.firstDate,
    this.lastDate,
  });

  final String label;
  final IconData icon;
  final DateTime? date;
  final ValueChanged<DateTime?> onDateSelected;
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date ?? DateTime.now(),
          firstDate: firstDate ?? DateTime(2000),
          lastDate: lastDate ?? DateTime(2100),
        );
        if (picked != null) {
          onDateSelected(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: date != null
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => onDateSelected(null),
                )
              : null,
        ),
        child: Text(
          date?.formatted ?? l10n.selectDate,
          style: TextStyle(color: date != null ? null : context.colors.outline),
        ),
      ),
    );
  }
}
