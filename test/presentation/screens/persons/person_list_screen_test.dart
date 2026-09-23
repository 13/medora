import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/persons/person_list_screen.dart';

const _ben = Person(id: 'p1', name: 'Ben');

class _FailingDeleteRepo implements PersonRepository {
  @override
  Future<Result<List<Person>>> getPersons() async =>
      const Result.success([_ben]);
  @override
  Future<Result<Person?>> getByTaxCode(String t) async =>
      const Result.success(null);
  @override
  Future<Result<Person>> savePerson(Person p) async => Result.success(p);
  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.failure('db down');
}

void main() {
  testWidgets('a failed delete shows a SnackBar', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          personRepositoryProvider.overrideWithValue(_FailingDeleteRepo()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: PersonListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    // Confirm the destructive dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
  });
}
