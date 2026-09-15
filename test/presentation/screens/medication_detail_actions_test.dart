import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/failing_medication_repo.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';

const _med = Medication(id: 'm1', name: 'Moment', quantity: 3);

Future<List<Override>> _overrides() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return [
    sharedPreferencesProvider.overrideWithValue(prefs),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.mobile),
    medicationRepositoryProvider.overrideWithValue(
      FailingMedicationRepo(medications: const [_med]),
    ),
  ];
}

/// Pumps the detail screen under a Navigator that has something to pop back
/// to, so a pop is observable.
Future<void> _pumpDetail(WidgetTester tester) async {
  await pumpMedoraApp(
    tester,
    Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        builder: (_) => const MedicationDetailScreen(medicationId: 'm1'),
      ),
    ),
    overrides: await _overrides(),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a failed archive shows a SnackBar and keeps the screen', (
    tester,
  ) async {
    await _pumpDetail(tester);
    expect(find.text('Moment'), findsWidgets);

    await _chooseMenuItem(tester, 'Archive');

    expect(find.text('Something went wrong: db down'), findsOneWidget);
    expect(find.byType(MedicationDetailScreen), findsOneWidget);
  });

  testWidgets('a failed delete shows a SnackBar and keeps the screen', (
    tester,
  ) async {
    await _pumpDetail(tester);

    await _chooseMenuItem(tester, 'Delete');
    // Confirm the destructive dialog.
    await tester.tap(find.widgetWithText(TextButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong: db down'), findsOneWidget);
    expect(find.byType(MedicationDetailScreen), findsOneWidget);
  });
}
