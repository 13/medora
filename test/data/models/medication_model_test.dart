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

  test('toJson omits ean when there is none', () {
    // A project that has not applied the ean migration still accepts the
    // row: the key is only sent when it carries a value (like deleted_at).
    const m = MedicationModel(id: 'm1', name: 'X', quantity: 1);
    expect(m.toJson().containsKey('ean'), isFalse);
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
