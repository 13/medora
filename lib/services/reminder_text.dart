/// Medora - Reminder notification text.
///
/// Pure text-building for dose reminders, shared between the background
/// notification service (no [BuildContext]) and the presentation layer's
/// [dosageLabel]-style formatters — so a notification body and its in-app
/// equivalent never disagree. Services must not import presentation code;
/// presentation may import this.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Localized "amount + unit" label for a dose, e.g. "1 Compresse" under
/// `it` where [DoseLog.displayDosage] would render the raw key "1 tablets".
///
/// Falls back to the stored free-text `dosage` (via [DoseLog.displayDosage])
/// whenever there is no amount/unit pair to localize.
String? dosageAmountLabel(AppLocalizations l10n, DoseLog dose) {
  final amount = dose.dosageAmount;
  final unitKey = (dose.dosageUnit != null && dose.dosageUnit!.isNotEmpty)
      ? dose.dosageUnit!
      : ((dose.medicationUnit != null && dose.medicationUnit!.isNotEmpty)
            ? dose.medicationUnit!
            : null);
  if (amount != null && unitKey != null) {
    final formatted = amount % 1 == 0
        ? amount.toInt().toString()
        : amount.toString();
    return '$formatted ${AppConstants.unitLabel(l10n, unitKey)}';
  }
  return dose.displayDosage;
}

/// The body text of a dose reminder notification, with the unit localized
/// (e.g. "1 Compresse — Tap to log your dose" under `it`, instead of the raw
/// key "1 tablets" that [DoseLog.displayDosage] would render).
String reminderBody(AppLocalizations l10n, DoseLog dose) {
  return l10n.notificationReminderBody(dosageAmountLabel(l10n, dose) ?? '');
}
