import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';

import 'golden_config.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('add medication ${b.name}', (tester) async {
      await pumpGolden(tester, const AddMedicationScreen(), brightness: b);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('add_medication_${b.name}.png'),
      );
    });
  }
}
