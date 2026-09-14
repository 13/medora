import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
