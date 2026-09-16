import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';

import 'golden_config.dart';

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('home ${b.name}', (tester) async {
      // 964 dp, not the default 915: the Low Stock card is Home's last
      // section, and at 915 the dashboard overflowed by 49 dp, so the card
      // was sliced by the viewport edge and the goldens quietly stopped
      // covering the only place it is rendered.
      await pumpGolden(tester, const HomeScreen(), brightness: b, height: 964);

      // A golden only guards what it can see. If a new section or a taller
      // card pushes Home past the viewport again, fail here loudly instead
      // of dropping it out of the image in silence.
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .maxScrollExtent,
        0,
        reason:
            'Home scrolls at the golden viewport, so the golden no longer '
            'covers its last section - raise pumpGolden height',
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('home_${b.name}.png'),
      );
    });
  }
}
