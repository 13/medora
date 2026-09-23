import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/treatment_rx_section.dart';

void main() {
  testWidgets('the heading is not the dosing plans\' "Prescriptions"', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23)),
          personsProvider.overrideWith((ref) async => const <Person>[]),
          rxForTreatmentProvider.overrideWith(
            (ref, id) async => const <RxWithDispensings>[],
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: TreatmentRxSection(
              treatment: Treatment(
                id: 't1',
                name: 'Flu',
                startDate: DateTime(2026, 9),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prescription slips'), findsOneWidget);
    expect(find.text('Prescriptions'), findsNothing);
  });
}
