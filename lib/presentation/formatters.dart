/// Medora - Presentation-layer formatters.
///
/// Anything that turns a domain value into text a user reads belongs here,
/// not on the entity: entities store raw keys (`tablets`, `drops`) and have
/// no access to [AppLocalizations].
library;

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

/// Localized "amount + unit" label for a prescription — the [dosageLabel]
/// twin for [Prescription], whose `dosage` text also stores the raw unit
/// key. [medicationUnit] is the fallback unit from the medication entity.
String prescriptionDosageLabel(
  AppLocalizations l10n,
  Prescription prescription, {
  String? medicationUnit,
}) {
  final amount = prescription.dosageAmount;
  final unitKey = prescription.dosageUnit ?? medicationUnit;
  if (amount != null && unitKey != null && unitKey.isNotEmpty) {
    final formatted = amount % 1 == 0
        ? amount.toInt().toString()
        : amount.toString();
    return '$formatted ${AppConstants.unitLabel(l10n, unitKey)}';
  }
  return prescription.displayDosage(medicationUnit: medicationUnit);
}
