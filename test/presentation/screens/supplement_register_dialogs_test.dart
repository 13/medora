import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/scanner/supplement_register_dialogs.dart';
import 'package:medora/services/supplement_registry_service.dart';

import '../../helpers/fake_supplement_registry.dart';
import '../../helpers/pump_app.dart';

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
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

  testWidgets('Download stores the register and returns true', (tester) async {
    final registry = FakeSupplementRegistry(syncedEntries: const [_zinco]);
    final context = await pumpHost(tester);
    final result = confirmAndDownloadSupplementRegister(context, registry);
    await tester.pumpAndSettle();
    expect(find.textContaining('Ministry of Health register'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(await result, isTrue);
    expect(registry.syncCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a failed download returns false', (tester) async {
    final registry = FakeSupplementRegistry(failSync: true);
    final context = await pumpHost(tester);
    final result = confirmAndDownloadSupplementRegister(context, registry);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(await result, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cancel returns null without downloading', (tester) async {
    final registry = FakeSupplementRegistry();
    final context = await pumpHost(tester);
    final result = confirmAndDownloadSupplementRegister(context, registry);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
    expect(registry.syncCalls, 0);
  });

  testWidgets('the picker returns the chosen product', (tester) async {
    const forte = SupplementEntry(
      code: '107018',
      product: 'ZINCO-C FORTE',
      company: 'SYGNUM SRL',
    );
    final context = await pumpHost(tester);
    final picked = showSupplementPicker(context, const [_zinco, forte]);
    await tester.pumpAndSettle();

    expect(find.text('Select product'), findsOneWidget);
    await tester.tap(find.text('ZINCO-C FORTE'));
    await tester.pumpAndSettle();

    expect(await picked, forte);
  });
}
