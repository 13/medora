/// The dashboard's low-stock links open the Medications tab filtered to low
/// stock, so the count they show and the list they open agree. A later visit
/// from the bottom bar opens the tab unfiltered, as before.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';

import '../../helpers/pump_shell.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  const lowNames = ['LS1', 'LS2', 'LS3', 'LS4', 'LS5'];

  /// Five medications at or under their minimum, two well stocked, one
  /// archived at zero (not low stock: archived rows are not counted).
  Future<void> seed() async {
    final db = await AppDatabase.instance.database;
    for (final (i, name) in lowNames.indexed) {
      await db.insert('medications', {
        'id': 'ls$i',
        'name': name,
        // The most urgent (furthest under its minimum) is LS5.
        'quantity': 5 - i,
        'minimum_stock_level': 5,
      });
    }
    for (final name in const ['Stocked A', 'Stocked B']) {
      await db.insert('medications', {
        'id': name,
        'name': name,
        'quantity': 30,
        'minimum_stock_level': 5,
      });
    }
    await db.insert('medications', {
      'id': 'old',
      'name': 'Archived Zero',
      'quantity': 0,
      'minimum_stock_level': 5,
      'is_archived': 1,
    });
  }

  Future<void> pump(WidgetTester tester) async {
    await seed();
    await pumpShell(tester, size: const Size(412, 1600));
  }

  void expectLowStockList(WidgetTester tester) {
    final list = find.byType(MedicationListScreen);
    expect(list, findsOneWidget);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 1);
    for (final name in lowNames) {
      expect(
        find.descendant(of: list, matching: find.text(name)),
        findsOneWidget,
        reason: '$name is low on stock',
      );
    }
    for (final name in const ['Stocked A', 'Stocked B', 'Archived Zero']) {
      expect(
        find.descendant(of: list, matching: find.text(name)),
        findsNothing,
        reason: '$name is not low on stock',
      );
    }
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Low Stock'),
    );
    expect(chip.selected, isTrue);
  }

  Future<void> backToDashboardAndMedications(WidgetTester tester) async {
    await openTab(tester, 0);
    await openTab(tester, 1);
    // From the bottom bar: unfiltered, as before.
    expect(find.text('Stocked A'), findsOneWidget);
    expect(find.text('LS1'), findsOneWidget);
    final all = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'All'),
    );
    expect(all.selected, isTrue);
  }

  testWidgets('the "2 more" row opens the low-stock list', (tester) async {
    await pump(tester);
    final more = find.widgetWithText(ListTile, '2 more');
    expect(more, findsOneWidget);
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expectLowStockList(tester);
    await backToDashboardAndMedications(tester);
  });

  testWidgets('the Low Stock "See All" opens the low-stock list', (
    tester,
  ) async {
    await pump(tester);
    final header = find
        .ancestor(
          of: find.text('Low Stock'),
          matching: find.byType(OverflowBar),
        )
        .first;
    final seeAll = find.descendant(of: header, matching: find.text('See All'));
    await tester.ensureVisible(seeAll);
    await tester.tap(seeAll);
    await tester.pumpAndSettle();
    expectLowStockList(tester);
    await backToDashboardAndMedications(tester);
  });

  testWidgets('the Low stock tile opens the low-stock list', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Low stock'));
    await tester.pumpAndSettle();
    expectLowStockList(tester);
  });

  testWidgets('the card shows the three furthest under their minimum', (
    tester,
  ) async {
    await pump(tester);
    for (final name in const ['LS3', 'LS4', 'LS5']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    for (final name in const ['LS1', 'LS2']) {
      expect(find.text(name), findsNothing, reason: name);
    }
  });
}
