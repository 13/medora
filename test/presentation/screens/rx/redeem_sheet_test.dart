import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';

void main() {
  test('proposed units multiply packs by the pack size in the description', () {
    const item = RxItem(id: 'i', description: 'Tachipirina 20 compresse');
    expect(proposedUnits(item, 2), 40);
  });

  test('without a pack size the packs themselves are proposed', () {
    const item = RxItem(id: 'i', description: 'Sciroppo 150 ml');
    expect(proposedUnits(item, 2), 2);
  });
}
