/// The dashboard has to show a medication that has already expired. The
/// expiry window used to start at today, so an expired box appeared nowhere
/// on Home while the card claimed every medication was within date.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  // A fixed clock: these tests assert expiry arithmetic, not doses, so
  // nothing here depends on the real wall clock.
  final now = DateTime(2026, 3, 4, 15);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  /// Home is a long ListView; a tall viewport puts every section on screen
  /// so the assertions do not have to scroll.
  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('an expired medication is on the dashboard, above an expiring '
      'one, and marked expired', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'soon',
      'name': 'Moment 200',
      'quantity': 5,
      'expiry_date': '2026-03-20',
    });
    await db.insert('medications', {
      'id': 'exp',
      'name': 'Bentelan',
      'quantity': 8,
      'expiry_date': '2025-12-01',
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // Both are on the card, expired first (the provider sorts by urgency,
    // and `.take(3)` must never drop the expired one).
    expect(find.text('Bentelan'), findsOneWidget);
    expect(find.text('Moment 200'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Bentelan')).dy,
      lessThan(tester.getTopLeft(find.text('Moment 200')).dy),
      reason: 'the expired medication must head the card',
    );

    // Visually distinct from "expiring soon": its own label and its own icon.
    // ExpiryBadge's colours are covered by expiry_badge_test.dart; what this
    // test pins is that Home reaches the expired branch at all.
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Expires in 16 days'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    // The empty state must stop lying.
    expect(find.text('All medications are within date'), findsNothing);

    // And the stat tile counts both.
    final tile = find
        .ancestor(of: find.text('Expiring'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);
  });

  testWidgets('with nothing expired or expiring the card says so', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'ok',
      'name': 'Aspirina',
      'quantity': 5,
      'expiry_date': '2027-01-01',
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('All medications are within date'), findsOneWidget);
    expect(find.text('Expired'), findsNothing);
    final tile = find
        .ancestor(of: find.text('Expiring'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('0')), findsOneWidget);
  });
}
