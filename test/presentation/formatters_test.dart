/// The prescription dose label reads as the user's language, with the unit
/// in the number the amount calls for.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';

void main() {
  Prescription rx({
    String dosage = '1 tablets',
    double? amount = 1,
    String? unit,
  }) => Prescription(
    id: 'p1',
    treatmentId: 't1',
    medicationId: 'm1',
    dosage: dosage,
    dosageAmount: amount,
    dosageUnit: unit,
    startTime: DateTime(2026, 3, 3, 8),
  );

  String label(
    String locale,
    Prescription p, {
    String? medicationUnit = 'tablets',
  }) => prescriptionDosageLabel(
    lookupAppLocalizations(Locale(locale)),
    p,
    medicationUnit: medicationUnit,
  );

  test('one tablet is singular in every language', () {
    expect(label('de', rx()), '1 Tablette');
    expect(label('it', rx()), '1 compressa');
    expect(label('en', rx()), '1 tablet');
  });

  test('more than one is plural', () {
    final two = rx(dosage: '2 tablets', amount: 2);
    expect(label('de', two), '2 Tabletten');
    expect(label('it', two), '2 compresse');
    expect(label('en', two), '2 tablets');
  });

  test('a fraction is plural and uses the language\'s decimal mark', () {
    final half = rx(dosage: '1.5 tablets', amount: 1.5);
    expect(label('de', half), '1,5 Tabletten');
    expect(label('it', half), '1,5 compresse');
    expect(label('en', half), '1.5 tablets');
  });

  test('the prescription\'s own unit wins over the medication\'s', () {
    final drops = rx(dosage: '1 drops', unit: 'drops');
    expect(label('de', drops), '1 Tropfen');
    expect(label('it', drops), '1 goccia');
    expect(label('en', drops), '1 drop');
  });

  test('without the medication, the unit key the sheet stored is still '
      'translated', () {
    // The sheet saves "<amount> <unit key>" when the medication's own unit
    // is used, so a medication that is no longer listed still reads right.
    expect(label('de', rx(), medicationUnit: null), '1 Tablette');
    expect(label('it', rx(), medicationUnit: null), '1 compressa');
  });

  test('an unknown unit and free text are shown as they are', () {
    expect(
      label('de', rx(dosage: '400 mg', amount: 400, unit: 'mg')),
      '400 mg',
    );
    expect(
      label('de', rx(dosage: '20 Tropfen', amount: null), medicationUnit: null),
      '20 Tropfen',
    );
    // A stored word that is no unit key is not taken for one.
    expect(
      label('de', rx(dosage: '1 Messlöffel'), medicationUnit: null),
      '1 Messlöffel',
    );
  });
}
