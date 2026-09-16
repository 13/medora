import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/medication/supplement_search_sheet.dart';
import 'package:medora/services/supplement_registry_service.dart';

import '../../helpers/fake_supplement_registry.dart';
import '../../helpers/pump_app.dart';

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);
const _zincoForte = SupplementEntry(
  code: '107019',
  product: 'ZINCO FORTE',
  company: 'ALFA SRL',
);
const _magnesio = SupplementEntry(
  code: '200001',
  product: 'MAGNESIO PLUS',
  company: 'BETA SPA',
);

void main() {
  /// Pumps an empty screen and returns a context below the MaterialApp.
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext context;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (ctx) {
          context = ctx;
          return const Scaffold();
        },
      ),
    );
    return context;
  }

  FakeSupplementRegistry registry() =>
      FakeSupplementRegistry(entries: const [_zinco, _zincoForte, _magnesio]);

  testWidgets('a query lists the matching products after the debounce', (
    tester,
  ) async {
    final service = registry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(); // the field repaints, the debounce is pending
    expect(service.searches, isEmpty);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(service.searches, ['zinc']);
    expect(find.text('ZINCO-C'), findsOneWidget);
    expect(find.text('ZINCO FORTE'), findsOneWidget);
    expect(find.text('SYGNUM SRL · 107018'), findsOneWidget);
    expect(find.text('MAGNESIO PLUS'), findsNothing);
  });

  testWidgets('tapping a row pops the sheet with that product', (tester) async {
    final context = await pumpHost(tester);
    final chosen = showSupplementSearchSheet(context, registry());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ZINCO-C'));
    await tester.pumpAndSettle();

    expect(await chosen, _zinco);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a query with no matches shows the empty state', (tester) async {
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, registry()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ferro');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('No results found'), findsOneWidget);
  });

  testWidgets('a one-character query never searches', (tester) async {
    final service = registry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'z');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(service.searches, isEmpty);
    expect(find.text('No results found'), findsNothing);
  });

  testWidgets('nothing overflows at 360x800', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, registry()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('ZINCO-C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
