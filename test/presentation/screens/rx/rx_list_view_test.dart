import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_list_view.dart';

import '../../../helpers/fake_attachment_repository.dart';

/// A person repository whose list can be mutated between pumps, so a test
/// can simulate Settings -> Persons deleting someone while this tab (which
/// never unmounts) is showing a filter set to them.
class _MutablePersonRepo implements PersonRepository {
  _MutablePersonRepo(this.persons);
  List<Person> persons;

  @override
  Future<Result<List<Person>>> getPersons() async => Result.success(persons);
  @override
  Future<Result<Person?>> getByTaxCode(String taxCode) async =>
      const Result.success(null);
  @override
  Future<Result<Person>> savePerson(Person person) async =>
      Result.success(person);
  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.success(null);
}

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
          // A real repository would try to open sqlite, which isn't set up
          // in these widget tests.
          attachmentRepositoryProvider.overrideWithValue(
            FakeAttachmentRepository(),
          ),
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
    // The subtitle combines the person's name with the validity.
    expect(find.text('Ben · 2 days left'), findsOneWidget);
  });

  testWidgets('filtering to one person hides the other person\'s prescription, '
      'and switching back to "All" shows both again', (tester) async {
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
          // A real repository would try to open sqlite, which isn't set up
          // in these widget tests.
          attachmentRepositoryProvider.overrideWithValue(
            FakeAttachmentRepository(),
          ),
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

    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All').last);
    await tester.pumpAndSettle();

    expect(find.text('Med a'), findsOneWidget);
    expect(find.text('Med b'), findsOneWidget);
  });

  testWidgets(
    'a filter set to a person who is then removed falls back to showing '
    'everyone, without throwing, whether or not the dropdown stays shown',
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
      const ben = Person(id: 'p1', name: 'Ben');
      const anna = Person(id: 'p2', name: 'Anna');
      const carla = Person(id: 'p3', name: 'Carla');
      final personRepo = _MutablePersonRepo([ben, anna, carla]);
      final container = ProviderContainer(
        overrides: [
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          // A real repository would try to open sqlite, which isn't set up
          // in these widget tests.
          attachmentRepositoryProvider.overrideWithValue(
            FakeAttachmentRepository(),
          ),
          personRepositoryProvider.overrideWithValue(personRepo),
          rxListProvider.overrideWith(
            (ref) async => [
              RxWithDispensings(rx('a', 'p1'), const []),
              RxWithDispensings(rx('b', 'p2'), const []),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: Scaffold(body: RxListView()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Filter to Anna: only her prescription shows.
      await tester.tap(find.byType(DropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anna').last);
      await tester.pumpAndSettle();
      expect(find.text('Med a'), findsNothing);
      expect(find.text('Med b'), findsOneWidget);

      // Settings -> Persons deletes Anna while this tab stays mounted; Ben
      // and Carla are still two people, so the dropdown itself stays put,
      // but its value no longer names an existing item.
      personRepo.persons = [ben, carla];
      container.invalidate(personsProvider);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButton<String?>), findsOneWidget);
      // The filter fell back to "All": nothing is hidden any more.
      expect(find.text('Med a'), findsOneWidget);
      expect(find.text('Med b'), findsOneWidget);

      // Carla goes too, down to one person: the dropdown itself disappears,
      // and the (already-reset) filter has no way to come back.
      personRepo.persons = [ben];
      container.invalidate(personsProvider);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButton<String?>), findsNothing);
      expect(find.text('Med a'), findsOneWidget);
      expect(find.text('Med b'), findsOneWidget);
    },
  );

  testWidgets('pulling the list down reads the prescriptions again', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          // A real repository would try to open sqlite, which isn't set up
          // in these widget tests.
          attachmentRepositoryProvider.overrideWithValue(
            FakeAttachmentRepository(),
          ),
          personsProvider.overrideWith((ref) async => const <Person>[]),
          rxListProvider.overrideWith((ref) async {
            reads++;
            return [
              RxWithDispensings(
                Rx(
                  id: 'r$reads',
                  kind: RxKind.ssn,
                  issuedOn: DateTime(2026, 9),
                  validUntil: DateTime(2026, 10),
                  items: [RxItem(id: 'i', description: 'Med $reads')],
                ),
                const [],
              ),
            ];
          }),
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
    expect(find.text('Med 1'), findsOneWidget);

    await tester.fling(find.text('Med 1'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(reads, 2);
    expect(find.text('Med 2'), findsOneWidget);
  });
}
