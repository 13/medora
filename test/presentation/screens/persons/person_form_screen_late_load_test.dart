import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/persons/person_form_screen.dart';

const _existing = Person(id: 'p1', name: 'Original Name');

class _LateRepo implements PersonRepository {
  _LateRepo(this.completer);
  final Completer<Result<List<Person>>> completer;
  final saved = <Person>[];

  @override
  Future<Result<List<Person>>> getPersons() => completer.future;
  @override
  Future<Result<Person?>> getByTaxCode(String t) async =>
      const Result.success(null);
  @override
  Future<Result<Person>> savePerson(Person p) async {
    saved.add(p);
    return Result.success(p);
  }

  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.success(null);
}

void main() {
  testWidgets('typed input survives a slow-resolving load and is saved to the '
      'existing person', (tester) async {
    final completer = Completer<Result<List<Person>>>();
    final repo = _LateRepo(completer);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [personRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: PersonFormScreen(personId: 'p1'),
        ),
      ),
    );
    // Let the screen build while getPersons() is still pending.
    await tester.pump();

    await tester.enterText(find.byKey(const Key('person_name')), 'Typed Name');

    // Now let the load resolve.
    completer.complete(const Result.success([_existing]));
    await tester.pumpAndSettle();

    // The typed name was not clobbered by the load.
    expect(find.text('Typed Name'), findsOneWidget);

    await tester.tap(find.byKey(const Key('person_save')));
    await tester.pumpAndSettle();

    expect(repo.saved.single.id, 'p1');
    expect(repo.saved.single.name, 'Typed Name');
  });
}
