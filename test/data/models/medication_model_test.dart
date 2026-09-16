import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/medication_model.dart';

void main() {
  test('fromJson normalizes image_path to a bare filename', () {
    final m = MedicationModel.fromJson({
      'id': 'm1',
      'name': 'X',
      'quantity': 1,
      'image_path':
          '/var/mobile/Containers/OLD/Documents/medication_photos/med_1.jpg',
    });
    expect(m.imagePath, 'med_1.jpg');
  });

  test('fromJson keeps a null image_path', () {
    final m = MedicationModel.fromJson({
      'id': 'm1',
      'name': 'X',
      'quantity': 1,
    });
    expect(m.imagePath, isNull);
  });

  test('toJson always sends ean, so clearing one propagates', () {
    // Review I1: PostgREST leaves a column alone when the key is absent, so
    // an omitted `ean` would keep a cleared EAN alive on the server and pull
    // it back onto every device. The key is always sent; a project that has
    // not applied `20260916000000_medication_ean.sql` is reported instead
    // (see `missingMedicationColumn`).
    const m = MedicationModel(id: 'm1', name: 'X', quantity: 1);
    final json = m.toJson();
    expect(json.containsKey('ean'), isTrue);
    expect(json['ean'], isNull);
  });

  test('fromJson reads an ean provisioned as a number', () {
    // A column added by hand as `bigint` would otherwise throw for every row
    // and stall the pull cursor forever.
    final m = MedicationModel.fromJson({
      'id': 'm1',
      'name': 'X',
      'quantity': 1,
      'ean': 8057737141836,
    });
    expect(m.ean, '8057737141836');
  });

  test('toJson sends the pack EAN when the medication has one', () {
    const m = MedicationModel(
      id: 'm1',
      name: 'X',
      quantity: 1,
      ean: '8057737141836',
    );
    expect(m.toJson()['ean'], '8057737141836');
  });
}
