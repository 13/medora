import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/biometric_gate.dart';
import 'package:medora/services/security_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'biometrics_enabled': true});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pumpGate(
    WidgetTester tester,
    AuthOutcome outcome,
  ) async {
    final container = await pumpMedoraApp(
      tester,
      BiometricGate(
        authenticate: () async => outcome,
        child: const Scaffold(body: Text('unlocked content')),
      ),
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    // The first attempt runs in a post-frame callback.
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('notEnrolled shows the reason and an escape hatch that unlocks', (
    tester,
  ) async {
    final container = await pumpGate(tester, AuthOutcome.notEnrolled);

    expect(
      find.text(
        'No biometrics or device lock set up — add one in system settings',
      ),
      findsOneWidget,
    );
    expect(find.text('unlocked content'), findsNothing);

    await tester.tap(find.text('Turn off app lock'));
    await tester.pumpAndSettle();

    expect(container.read(biometricsEnabledProvider), isFalse);
    expect(find.text('unlocked content'), findsOneWidget);
  });

  testWidgets('success shows the child', (tester) async {
    await pumpGate(tester, AuthOutcome.success);

    expect(find.text('unlocked content'), findsOneWidget);
    expect(find.text('Unlock Medora'), findsNothing);
  });

  testWidgets('cancelled leaves the retry button and no message or opt-out', (
    tester,
  ) async {
    await pumpGate(tester, AuthOutcome.cancelled);

    expect(find.text('Unlock Medora'), findsOneWidget);
    expect(find.text('Turn off app lock'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('unlocked content'), findsNothing);
  });

  testWidgets('lockedOut asks the user to wait but keeps the lock', (
    tester,
  ) async {
    await pumpGate(tester, AuthOutcome.lockedOut);

    expect(find.text('Too many attempts — try again later'), findsOneWidget);
    expect(find.text('Turn off app lock'), findsNothing);
    expect(find.text('Unlock Medora'), findsOneWidget);
  });
}
