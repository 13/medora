/// The dose schedule with two doses already due, so the "Take all due" bar
/// above the list is covered — `doses_*.png` has only one due dose and never
/// renders it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';

import 'golden_config.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('doses take all due ${b.name}', (tester) async {
      await pumpGolden(
        tester,
        const DoseScheduleScreen(),
        brightness: b,
        doses: goldenDosesTwoDue(),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('doses_take_all_${b.name}.png'),
      );
    });
  }
}
