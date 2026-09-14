import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';

import 'golden_config.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('doses ${b.name}', (tester) async {
      await pumpGolden(tester, const DoseScheduleScreen(), brightness: b);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('doses_${b.name}.png'),
      );
    });
  }
}
