/// The Medications filter chips: All, Low Stock, Expiring Soon, Archived.
///
/// "Expiring Soon" used to be a combined "Low Stock · Expiring Soon" chip
/// next to "Low Stock", which read as the same filter twice. It now selects
/// exactly what the dashboard's expiry card counts (`expiringSoonProvider`):
/// expired or expiring within the warning window, not archived.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
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

  const expiring = ['Lapsed box', 'In 10 days', 'In 30 days'];
  const notExpiring = ['In 31 days', 'No expiry', 'Low only', 'Archived soon'];

  Future<void> seed() async {
    final db = await AppDatabase.instance.database;
    Future<void> add(
      String name, {
      String? expiry,
      int quantity = 30,
      bool archived = false,
    }) => db.insert('medications', {
      'id': name,
      'name': name,
      'quantity': quantity,
      'minimum_stock_level': 5,
      if (expiry != null) 'expiry_date': expiry,
      'is_archived': archived ? 1 : 0,
    });
    await add('Lapsed box', expiry: '2026-03-03');
    await add('In 10 days', expiry: '2026-03-14');
    await add('In 30 days', expiry: '2026-04-03');
    await add('In 31 days', expiry: '2026-04-04');
    await add('No expiry');
    // Low on stock but well within date: not an expiry row.
    await add('Low only', expiry: '2027-01-01', quantity: 1);
    await add('Archived soon', expiry: '2026-03-10', archived: true);
  }

  Future<void> pumpList(WidgetTester tester, {String locale = 'en'}) async {
    tester.view.physicalSize = const Size(412, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMedoraApp(
      tester,
      const MedicationListScreen(),
      overrides: await overrides(),
      locale: Locale(locale),
    );
    await tester.pumpAndSettle();
  }

  List<String> chipLabels(WidgetTester tester) => [
    for (final chip in tester.widgetList<FilterChip>(find.byType(FilterChip)))
      (chip.label as Text).data!,
  ];

  for (final locale in const ['en', 'de', 'it']) {
    testWidgets('$locale: the chips are All, Low Stock, Expiring Soon and '
        'Archived, with no combined chip', (tester) async {
      await pumpList(tester, locale: locale);
      final l10n = lookupAppLocalizations(Locale(locale));
      expect(chipLabels(tester), [
        l10n.all,
        l10n.lowStock,
        l10n.expiringSoon,
        l10n.archived,
      ]);
    });
  }

  testWidgets('Expiring Soon shows the rows the dashboard counts as '
      'expiring, and nothing else', (tester) async {
    await seed();
    await pumpList(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'Expiring Soon'));
    await tester.pumpAndSettle();

    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Expiring Soon'),
    );
    expect(chip.selected, isTrue);
    for (final name in expiring) {
      expect(find.text(name), findsOneWidget, reason: '$name is expiring');
    }
    for (final name in notExpiring) {
      expect(find.text(name), findsNothing, reason: '$name is not expiring');
    }

    // The same set as the dashboard card's source.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MedicationListScreen)),
    );
    final dashboard = await container.read(expiringSoonProvider.future);
    expect(dashboard.map((m) => m.name).toSet(), expiring.toSet());
  });

  testWidgets('Low Stock still shows only the rows low on stock', (
    tester,
  ) async {
    await seed();
    await pumpList(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'Low Stock'));
    await tester.pumpAndSettle();
    expect(find.text('Low only'), findsOneWidget);
    for (final name in [...expiring, 'In 31 days', 'No expiry']) {
      expect(find.text(name), findsNothing, reason: name);
    }
  });
}
