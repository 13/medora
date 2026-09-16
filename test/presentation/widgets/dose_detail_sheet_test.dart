import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/failing_dose_repo.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

class _Host extends ConsumerWidget {
  const _Host({required this.dose});

  final DoseLog dose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () =>
              showDoseDetailBottomSheet(context: context, dose: dose, ref: ref),
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
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
  ];

  testWidgets('a failed Take reports the error instead of closing silently', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      s.prescriptionId,
      DateTime.now().add(const Duration(hours: 1)),
    );

    await pumpMedoraApp(
      tester,
      _Host(
        dose: DoseLog(
          id: doseId,
          prescriptionId: s.prescriptionId,
          scheduledTime: DateTime.now().add(const Duration(hours: 1)),
          medicationName: 'Tachipirina',
        ),
      ),
      overrides: [
        ...await overrides(),
        doseLogRepositoryProvider.overrideWithValue(
          FailingTakeRepo(
            DoseLogRepositoryImpl(
              localDatasource: DoseLogLocalDatasource(),
              prescriptionLocal: PrescriptionLocalDatasource(),
            ),
          ),
        ),
      ],
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Take'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'pending',
    );
  });

  testWidgets('a successful Skip closes the sheet without an error', (
    tester,
  ) async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      s.prescriptionId,
      DateTime.now().add(const Duration(hours: 1)),
    );

    await pumpMedoraApp(
      tester,
      _Host(
        dose: DoseLog(
          id: doseId,
          prescriptionId: s.prescriptionId,
          scheduledTime: DateTime.now().add(const Duration(hours: 1)),
          medicationName: 'Tachipirina',
        ),
      ),
      overrides: await overrides(),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Skip'), findsNothing);
    expect(
      (await db.query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [doseId],
      )).single['status'],
      'skipped',
    );
  });
}
