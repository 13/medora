import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_text.dart';

void main() {
  test('reminder body localizes the unit in Italian', () {
    final l10n = lookupAppLocalizations(const Locale('it'));
    final dose = DoseLog(
      id: 'd',
      prescriptionId: 'p',
      scheduledTime: DateTime(2026, 3, 4, 8),
      dosageAmount: 1,
      medicationUnit: 'tablets',
    );
    final body = reminderBody(l10n, dose);
    expect(body, isNot(contains('tablets')));
    expect(body, contains(l10n.unitTablets));
  });

  test('reminder body falls back to the stored dosage text with no unit', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final dose = DoseLog(
      id: 'd',
      prescriptionId: 'p',
      scheduledTime: DateTime(2026, 3, 4, 8),
      dosage: '20 Tropfen',
    );
    final body = reminderBody(l10n, dose);
    expect(body, l10n.notificationReminderBody('20 Tropfen'));
  });

  test('dosageUnit overrides medicationUnit', () {
    final l10n = lookupAppLocalizations(const Locale('de'));
    final dose = DoseLog(
      id: 'd',
      prescriptionId: 'p',
      scheduledTime: DateTime(2026, 3, 4, 8),
      dosageAmount: 2,
      dosageUnit: 'drops',
      medicationUnit: 'tablets',
    );
    final body = reminderBody(l10n, dose);
    expect(body, contains(l10n.unitDrops));
    expect(body, isNot(contains(l10n.unitTablets)));
  });
}
