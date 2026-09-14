import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// Host screen with a single button that opens the prescription sheet —
/// mirrors how [TreatmentDetailScreen] invokes it.
class _Host extends ConsumerWidget {
  const _Host({required this.treatmentId, required this.pickTime});

  final String treatmentId;
  final Future<TimeOfDay?> Function(BuildContext, TimeOfDay) pickTime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showPrescriptionSheet(
            context,
            ref,
            treatmentId: treatmentId,
            pickTime: pickTime,
          ),
          child: const Text('Open'),
        ),
      ),
    );
  }
}

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    reminderPortProvider.overrideWithValue(FakePort()),
  ];

  testWidgets(
    'times-per-day: tapping + adds a custom time chip; saving without a medication shows the validator',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);

      await pumpMedoraApp(
        tester,
        _Host(
          treatmentId: seeded.treatmentId,
          pickTime: (_, _) async => const TimeOfDay(hour: 7, minute: 30),
        ),
        overrides: await overrides(),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Switch to times-per-day schedule.
      await tester.tap(find.text('Times per Day'));
      await tester.pumpAndSettle();

      // Tap the trailing "+" chip — overridden pickTime returns 07:30.
      await tester.tap(find.widgetWithIcon(ActionChip, Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('07:30'), findsOneWidget);

      // No medication selected yet: only the dropdown hint shows the text.
      expect(find.text('Select Medication'), findsOneWidget);

      // Tap Save — medication is required.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pump();

      // The hint plus the validator error text both read "Select Medication".
      expect(find.text('Select Medication'), findsNWidgets(2));
    },
  );
}
