import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/scanner/supplement_routing.dart';
import 'package:medora/services/supplement_registry_service.dart';

import '../../helpers/fake_supplement_registry.dart';

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

  group('findSupplementByCodes', () {
    test('the primary code is used when it matches', () async {
      final registry = FakeSupplementRegistry(entries: const [zinco]);
      final found = await findSupplementByCodes(registry, '107018', const [
        '707018',
      ]);
      expect(found.code, '107018');
      expect(found.matches, [zinco]);
    });

    test(
      'a missing primary falls back to the first matching alternative',
      () async {
        final registry = FakeSupplementRegistry(entries: const [zinco]);
        final found = await findSupplementByCodes(registry, '707018', const [
          '701018',
          '107018',
        ]);
        expect(found.code, '107018');
        expect(found.matches, [zinco]);
      },
    );

    test('no match keeps the primary code with no matches', () async {
      final registry = FakeSupplementRegistry(entries: const [zinco]);
      final found = await findSupplementByCodes(registry, '707018', const [
        '101018',
      ]);
      expect(found.code, '707018');
      expect(found.matches, isEmpty);
    });

    test('without alternatives only the primary code is looked up', () async {
      final registry = FakeSupplementRegistry(entries: const [zinco]);
      final found = await findSupplementByCodes(registry, '54321');
      expect(found.code, '54321');
      expect(found.matches, isEmpty);
    });
  });

  test('the Add Medication location carries the encoded code', () {
    expect(
      addMedicationWithBarcode('107018'),
      '/medications/add?barcode=107018',
    );
    expect(addMedicationWithBarcode('A 1'), '/medications/add?barcode=A+1');
  });
}
