/// Medora - Presentation-layer formatters.
///
/// Anything that turns a domain value into text a user reads belongs here,
/// not on the entity: entities store raw keys (`tablets`, `drops`) and have
/// no access to [AppLocalizations].
library;

import 'package:intl/intl.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_text.dart';

/// Localized "amount + unit" label for a dose, e.g. "1 Compresse" under
/// `it` where [DoseLog.displayDosage] would render the raw key "1 tablets".
///
/// Falls back to the stored free-text `dosage` (via [DoseLog.displayDosage])
/// whenever there is no amount/unit pair to localize, and returns null when
/// there is nothing to show at all. Delegates to [dosageAmountLabel] so this
/// stays identical to the text a dose's reminder notification shows.
String? dosageLabel(AppLocalizations l10n, DoseLog dose) =>
    dosageAmountLabel(l10n, dose);

/// Localized "amount + unit" label for a prescription, e.g. "1 Tablette"
/// or "2 compresse": the [dosageLabel] twin for [Prescription], whose
/// `dosage` text also stores the raw unit key. Unlike the stock labels, the
/// unit agrees with the amount, and the amount uses the language's decimal
/// mark ("1,5 Tabletten"), since this label is also shared as text.
///
/// The unit is the prescription's own, else [medicationUnit] (the
/// medication's), else the unit key the prescription sheet stored after the
/// amount ("1 tablets"). Falls back to the stored free-text `dosage`.
String prescriptionDosageLabel(
  AppLocalizations l10n,
  Prescription prescription, {
  String? medicationUnit,
}) {
  final amount = prescription.dosageAmount;
  final unitKey = [
    prescription.dosageUnit,
    medicationUnit,
    _storedUnitKey(prescription.dosage),
  ].firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
  if (amount != null && unitKey != null) {
    final number = NumberFormat.decimalPattern(l10n.localeName).format(amount);
    return '$number ${l10n.dosageUnitName(amount, unitKey)}';
  }
  return prescription.displayDosage(medicationUnit: medicationUnit);
}

/// The unit key at the end of a dosage the prescription sheet saved
/// ("1 tablets"), or null when the text ends in anything else.
String? _storedUnitKey(String dosage) {
  final word = RegExp(r'^\S+\s+(\S+)$').firstMatch(dosage.trim())?.group(1);
  return AppConstants.quantityUnitKeys.contains(word) ? word : null;
}
