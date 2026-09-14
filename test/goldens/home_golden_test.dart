import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';

import 'golden_config.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('home ${b.name}', (tester) async {
      await pumpGolden(tester, const HomeScreen(), brightness: b);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('home_${b.name}.png'),
      );
    });
  }
}
