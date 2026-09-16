import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('shows the remaining days from the injected clock', (
    tester,
  ) async {
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ExpiryBadge(
          expiryDate: DateTime(2026, 3, 10),
          now: DateTime(2026, 3, 4),
        ),
      ),
    );

    expect(find.text('Expires in 6 days'), findsOneWidget);
  });

  testWidgets('shows expired once the clock passes the expiry date', (
    tester,
  ) async {
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ExpiryBadge(
          expiryDate: DateTime(2026, 3, 10),
          now: DateTime(2026, 3, 11),
        ),
      ),
    );

    expect(find.text('Expired'), findsOneWidget);
  });

  testWidgets('shows valid well before the expiry date', (tester) async {
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ExpiryBadge(
          expiryDate: DateTime(2026, 12, 31),
          now: DateTime(2026, 3, 4),
        ),
      ),
    );

    expect(find.text('Valid'), findsOneWidget);
  });

  testWidgets('renders nothing without an expiry date', (tester) async {
    await pumpMedoraApp(
      tester,
      Scaffold(body: ExpiryBadge(expiryDate: null, now: DateTime(2026, 3, 4))),
    );

    expect(find.byType(Container), findsNothing);
  });

  // The amber window is a single number, shared with `expiringSoonProvider`
  // (medication_providers.dart). These two cases are written in terms of
  // AppConstants.expiryWarningDays rather than 30, so raising the constant
  // moves the provider's window and the badge's colours together instead of
  // leaving the card to draw a green "Valid" pill on a row it just flagged.
  testWidgets('the last day of the warning window is still amber', (
    tester,
  ) async {
    final now = DateTime(2026, 3, 4);
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ExpiryBadge(
          expiryDate: DateTime(2026, 3, 4 + AppConstants.expiryWarningDays),
          now: now,
        ),
      ),
    );

    expect(find.text('Valid'), findsNothing);
    expect(
      find.textContaining('${AppConstants.expiryWarningDays}'),
      findsOneWidget,
    );
  });

  testWidgets('one day past the warning window is valid', (tester) async {
    final now = DateTime(2026, 3, 4);
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ExpiryBadge(
          expiryDate: DateTime(2026, 3, 5 + AppConstants.expiryWarningDays),
          now: now,
        ),
      ),
    );

    expect(find.text('Valid'), findsOneWidget);
  });

  test('the badge takes its threshold from AppConstants, not a literal', () {
    // A behavioural test cannot catch this: the constant is compile-time, so
    // both copies read 30 today and agree by coincidence. What must hold is
    // that there is only one copy.
    final source = File(
      'lib/presentation/widgets/shared_widgets.dart',
    ).readAsStringSync();

    expect(
      // `< 0` is the expired branch and is genuinely zero; what must not
      // reappear is a second copy of the warning window's length.
      RegExp(r'daysUntilExpiry\s*<=?\s*[1-9]').hasMatch(source),
      isFalse,
      reason:
          'ExpiryBadge compares daysUntilExpiry against a hardcoded number; '
          'use AppConstants.expiryWarningDays so the badge and '
          'expiringSoonProvider cannot drift apart',
    );
    expect(source, contains('AppConstants.expiryWarningDays'));
  });
}
