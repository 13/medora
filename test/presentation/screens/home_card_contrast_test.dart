import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/contrast.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<void> checkContrast(WidgetTester tester, Brightness brightness) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final overrides = <Override>[
      sharedPreferencesProvider.overrideWithValue(prefs),
      syncStartupDelayProvider.overrideWithValue(Duration.zero),
      reminderPortProvider.overrideWithValue(FakePort()),
    ];

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: overrides,
      brightness: brightness,
    );
    await tester.pump(const Duration(milliseconds: 100));

    final containers = tester.widgetList<Container>(find.byType(Container));
    final gradientContainer = containers.firstWhere(
      (c) => (c.decoration as BoxDecoration?)?.gradient != null,
      orElse: () => throw StateError('No gradient Container found on Home screen'),
    );
    final gradient = (gradientContainer.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors.length, 2);

    final theme = Theme.of(tester.element(find.byType(HomeScreen)));
    final onPrimary = theme.colorScheme.onPrimary;

    for (final stop in gradient.colors) {
      expect(
        contrastRatio(onPrimary, stop),
        greaterThanOrEqualTo(3.0),
        reason: '$brightness: onPrimary $onPrimary vs gradient stop $stop',
      );
    }
  }

  testWidgets('Home gradient card keeps onPrimary legible in light mode', (tester) async {
    await checkContrast(tester, Brightness.light);
  });

  testWidgets('Home gradient card keeps onPrimary legible in dark mode', (tester) async {
    await checkContrast(tester, Brightness.dark);
  });
}
