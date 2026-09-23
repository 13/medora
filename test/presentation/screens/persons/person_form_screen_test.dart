import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/persons/person_form_screen.dart';

class _Repo implements PersonRepository {
  final saved = <Person>[];
  @override
  Future<Result<Person>> savePerson(Person p) async {
    saved.add(p);
    return Result.success(p);
  }

  @override
  Future<Result<List<Person>>> getPersons() async => Result.success(saved);
  @override
  Future<Result<Person?>> getByTaxCode(String t) async =>
      const Result.success(null);
  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.success(null);
}

void main() {
  Future<_Repo> pump(WidgetTester tester) async {
    final repo = _Repo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [personRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: PersonFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('an invalid tax code blocks saving', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('person_name')), 'Ben');
    await tester.enterText(
      find.byKey(const Key('person_tax_code')),
      'RSSMRA85T10A562T',
    );
    await tester.tap(find.byKey(const Key('person_save')));
    await tester.pumpAndSettle();
    expect(find.text('Not a valid tax code'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });

  testWidgets('a valid person is saved normalised', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('person_name')), 'Ben');
    await tester.enterText(
      find.byKey(const Key('person_tax_code')),
      'rss mra85t10a562s',
    );
    await tester.enterText(
      find.byKey(const Key('person_exemptions')),
      'e01, 048',
    );
    await tester.tap(find.byKey(const Key('person_save')));
    await tester.pumpAndSettle();
    expect(repo.saved.single.taxCode, 'RSSMRA85T10A562S');
    expect(repo.saved.single.exemptions, ['E01', '048']);
  });
}
