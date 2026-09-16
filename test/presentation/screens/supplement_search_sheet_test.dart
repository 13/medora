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

/// A register whose search throws while [fail] is set, like a corrupt or
/// unopenable database file.
class _FailingRegistry extends FakeSupplementRegistry {
  _FailingRegistry({super.entries});

  bool fail = true;

  @override
  Future<List<SupplementEntry>> searchByName(String query, {int limit = 50}) {
    if (!fail) return super.searchByName(query, limit: limit);
    searches.add(query);
    return Future<List<SupplementEntry>>.error(StateError('database corrupt'));
  }
}

/// A register whose searches complete only when the test says so, one
/// [Completer] per query.
class _ControlledRegistry extends FakeSupplementRegistry {
  final pending = <String, Completer<List<SupplementEntry>>>{};

  @override
  Future<List<SupplementEntry>> searchByName(String query, {int limit = 50}) {
    searches.add(query);
    return (pending[query] = Completer<List<SupplementEntry>>()).future;
  }
}

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

  testWidgets('a failed search shows the error, not the empty state', (
    tester,
  ) async {
    final service = _FailingRegistry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(service.searches, ['zinc']);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('No results found'), findsNothing);
  });

  testWidgets('a search that succeeds after a failure clears the error', (
    tester,
  ) async {
    final service = _FailingRegistry(entries: const [_zinco, _zincoForte]);
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);

    service.fail = false;
    await tester.enterText(find.byType(TextField), 'zinco');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('ZINCO-C'), findsOneWidget);
  });

  testWidgets('the results stay on screen while the next query is pending', (
    tester,
  ) async {
    final service = _ControlledRegistry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    service.pending['zinc']!.complete(const [_zinco, _zincoForte]);
    await tester.pumpAndSettle();
    expect(find.text('ZINCO-C'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zinco');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    // The previous answer is still readable and still scrollable.
    expect(find.text('ZINCO-C'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    service.pending['zinco']!.complete(const [_zincoForte]);
    await tester.pumpAndSettle();
    expect(find.text('ZINCO-C'), findsNothing);
    expect(find.text('ZINCO FORTE'), findsOneWidget);
  });

  testWidgets('an overtaken search never overwrites the newer results', (
    tester,
  ) async {
    final service = _ControlledRegistry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField), 'zinco');
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.searches, ['zinc', 'zinco']);

    // The newer query answers first, the older one afterwards.
    service.pending['zinco']!.complete(const [_zincoForte]);
    await tester.pumpAndSettle();
    service.pending['zinc']!.complete(const [_zinco, _zincoForte, _magnesio]);
    await tester.pumpAndSettle();

    expect(find.text('ZINCO FORTE'), findsOneWidget);
    expect(find.text('ZINCO-C'), findsNothing);
    expect(find.text('MAGNESIO PLUS'), findsNothing);
  });

  testWidgets('closing the sheet mid-search throws nothing', (tester) async {
    final service = _ControlledRegistry();
    final context = await pumpHost(tester);
    unawaited(showSupplementSearchSheet(context, service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zinc');
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.searches, ['zinc']); // in flight

    await tester.tapAt(const Offset(5, 5)); // dismiss the sheet
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    // The answer arrives after the sheet is gone: no setState on a dead State.
    service.pending['zinc']!.complete(const [_zinco]);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400)); // any stray timer

    expect(tester.takeException(), isNull);
  });
}
