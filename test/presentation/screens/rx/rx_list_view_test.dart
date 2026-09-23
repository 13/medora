import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_list_view.dart';

void main() {
  testWidgets('open prescriptions come first, soonest to expire on top; '
      'expired ones sit in the done group', (tester) async {
    Rx rx(String id, DateTime until) => Rx(
      id: id,
      personId: 'p1',
      kind: RxKind.ssn,
      nre: id.padRight(15, '0').toUpperCase(),
      issuedOn: DateTime(2026, 9),
      validUntil: until,
      items: [RxItem(id: 'i', description: 'Med $id')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          rxListProvider.overrideWith(
            (ref) async => [
              RxWithDispensings(rx('late', DateTime(2026, 10, 20)), const []),
              RxWithDispensings(rx('soon', DateTime(2026, 9, 25)), const []),
              RxWithDispensings(rx('gone', DateTime(2026, 9)), const []),
            ],
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: RxListView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final soon = tester.getTopLeft(find.text('Med soon')).dy;
    final late = tester.getTopLeft(find.text('Med late')).dy;
    expect(soon, lessThan(late));
    expect(find.text('Done & expired'), findsOneWidget);
    // The subtitle combines the person's name with the validity ("Ben · 2
    // days left"), so a substring match is used rather than an exact one.
    expect(find.textContaining('2 days left'), findsOneWidget);
  });

  testWidgets(
    'filtering to one person hides the other person\'s prescription',
    (tester) async {
      Rx rx(String id, String personId) => Rx(
        id: id,
        personId: personId,
        kind: RxKind.ssn,
        nre: id.padRight(15, '0').toUpperCase(),
        issuedOn: DateTime(2026, 9),
        validUntil: DateTime(2026, 10),
        items: [RxItem(id: 'i', description: 'Med $id')],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
            personsProvider.overrideWith(
              (ref) async => const [
                Person(id: 'p1', name: 'Ben'),
                Person(id: 'p2', name: 'Anna'),
              ],
            ),
            rxListProvider.overrideWith(
              (ref) async => [
                RxWithDispensings(rx('a', 'p1'), const []),
                RxWithDispensings(rx('b', 'p2'), const []),
              ],
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: Scaffold(body: RxListView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Med a'), findsOneWidget);
      expect(find.text('Med b'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ben').last);
      await tester.pumpAndSettle();

      expect(find.text('Med a'), findsOneWidget);
      expect(find.text('Med b'), findsNothing);
    },
  );
}
