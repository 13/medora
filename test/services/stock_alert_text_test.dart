import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

StockAlert _alert(StockAlertKind kind, {int days = 0, int quantity = 0}) =>
    StockAlert(
      id: 1,
      medicationId: 'm',
      medicationName: 'Aspirin',
      kind: kind,
      when: DateTime(2026, 9, 17, 9),
      days: days,
      quantity: quantity,
    );

String _expiry(int days, {AppLocalizations? l10n}) =>
    ReminderService.stockAlertBody(
      _alert(StockAlertKind.expiry, days: days),
      l10n: l10n,
    );

String _lowStock(int quantity, {AppLocalizations? l10n}) =>
    ReminderService.stockAlertBody(
      _alert(StockAlertKind.lowStock, quantity: quantity),
      l10n: l10n,
    );

/// The exact wording each locale must produce at 0, 1 and 2.
///
/// Spelled out rather than compared against the same getter that produces
/// them: the point is that the `=0`/`=1` plural branches are reached at all
/// (German and Italian have no CLDR "zero" or "one" category for these
/// numbers, so they are only reached through explicit-number handling) and
/// that neither language ends up reading "in 1 Tagen" or "ne restano 1".
const _expected = {
  'en': [
    'Aspirin expires today',
    'Aspirin expires tomorrow',
    'Aspirin expires in 2 days',
    'Aspirin: none left',
    'Aspirin: 1 left',
    'Aspirin: 2 left',
    'Expiring soon',
    'Running low',
  ],
  'de': [
    'Aspirin läuft heute ab',
    'Aspirin läuft morgen ab',
    'Aspirin läuft in 2 Tagen ab',
    'Aspirin: nichts mehr übrig',
    'Aspirin: noch 1',
    'Aspirin: noch 2',
    'Läuft bald ab',
    'Fast aufgebraucht',
  ],
  'it': [
    'Aspirin scade oggi',
    'Aspirin scade domani',
    'Aspirin scade tra 2 giorni',
    'Aspirin: esaurito',
    'Aspirin: ne resta 1',
    'Aspirin: ne restano 2',
    'In scadenza',
    'Scorte in esaurimento',
  ],
};

void main() {
  _expected.forEach((code, expected) {
    test('$code stock and expiry notifications read naturally', () {
      final l10n = lookupAppLocalizations(Locale(code));

      expect(_expiry(0, l10n: l10n), expected[0]);
      expect(_expiry(1, l10n: l10n), expected[1]);
      expect(_expiry(2, l10n: l10n), expected[2]);
      expect(_lowStock(0, l10n: l10n), expected[3]);
      expect(_lowStock(1, l10n: l10n), expected[4]);
      expect(_lowStock(2, l10n: l10n), expected[5]);
      expect(
        ReminderService.stockAlertTitle(StockAlertKind.expiry, l10n: l10n),
        expected[6],
      );
      expect(
        ReminderService.stockAlertTitle(StockAlertKind.lowStock, l10n: l10n),
        expected[7],
      );
    });
  });

  test('an unsupported platform locale falls back to English', () {
    // No AppLocalizations for French, so the service's own strings answer.
    ReminderService.localeResolver = () => const Locale('fr');
    addTearDown(() => ReminderService.localeResolver = null);

    expect(_expiry(0), 'Aspirin expires today');
    expect(_expiry(1), 'Aspirin expires tomorrow');
    expect(_expiry(2), 'Aspirin expires in 2 days');
    expect(_lowStock(0), 'Aspirin: none left');
    expect(_lowStock(1), 'Aspirin: 1 left');
    expect(_lowStock(2), 'Aspirin: 2 left');
    expect(
      ReminderService.stockAlertTitle(StockAlertKind.expiry),
      'Expiring soon',
    );
    expect(
      ReminderService.stockAlertTitle(StockAlertKind.lowStock),
      'Running low',
    );
  });
}
