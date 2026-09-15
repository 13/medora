import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/scanner/supplement_routing.dart';
import 'package:medora/services/supplement_registry_service.dart';

void main() {
  const zinco = SupplementEntry(
    code: '107018',
    product: 'ZINCO-C',
    company: 'SYGNUM SRL',
  );
  const other = SupplementEntry(
    code: '107018',
    product: 'ZINCO-C FORTE',
    company: 'SYGNUM SRL',
  );

  test('no match opens Add Medication with the code', () {
    expect(supplementRouteFor(const []), isA<SupplementNotFound>());
  });

  test('one match prefills Add Medication', () {
    final route = supplementRouteFor(const [zinco]);
    expect(route, isA<SupplementPrefill>());
    expect((route as SupplementPrefill).entry, zinco);
  });

  test('several matches ask the user to pick', () {
    final route = supplementRouteFor(const [zinco, other]);
    expect(route, isA<SupplementPick>());
    expect((route as SupplementPick).entries, [zinco, other]);
  });

  test('the Add Medication location carries the encoded code', () {
    expect(
      addMedicationWithBarcode('107018'),
      '/medications/add?barcode=107018',
    );
    expect(addMedicationWithBarcode('A 1'), '/medications/add?barcode=A+1');
  });
}
