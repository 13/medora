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
}
