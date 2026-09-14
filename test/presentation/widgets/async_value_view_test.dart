import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('shows data', (tester) async {
    await tester.pumpWidget(_wrap(AsyncValueView<int>(value: const AsyncData(3), data: (v) => Text('v=$v'))));
    expect(find.text('v=3'), findsOneWidget);
  });

  testWidgets('shows empty when emptyWhen matches', (tester) async {
    await tester.pumpWidget(_wrap(AsyncValueView<List<int>>(
      value: const AsyncData([]), emptyWhen: (l) => l.isEmpty, empty: const Text('nothing'), data: (_) => const Text('data'))));
    expect(find.text('nothing'), findsOneWidget);
    expect(find.text('data'), findsNothing);
  });

  testWidgets('shows generic error with retry and hides raw message until expanded', (tester) async {
    var retried = 0;
    await tester.pumpWidget(_wrap(AsyncValueView<int>(
      value: AsyncError(StateError('boom'), StackTrace.empty), data: (_) => const SizedBox(), onRetry: () async => retried++)));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });

  testWidgets('shows loading', (tester) async {
    await tester.pumpWidget(_wrap(AsyncValueView<int>(value: const AsyncLoading(), data: (_) => const SizedBox())));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
