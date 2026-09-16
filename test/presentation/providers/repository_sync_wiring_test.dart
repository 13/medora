/// The repository providers hand their repositories the one push path: in
/// cloud mode a write asks the sync service for a cycle, in local-only mode
/// it asks for nothing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/sync_service.dart';

import '../../helpers/fake_remotes.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// A sync service that only counts the cycles asked of it.
class _CountingSyncService extends SyncService {
  _CountingSyncService()
    : super(
        medicationLocal: MedicationLocalDatasource(),
        medicationRemote: null,
        treatmentLocal: TreatmentLocalDatasource(),
        treatmentRemote: null,
        prescriptionLocal: PrescriptionLocalDatasource(),
        prescriptionRemote: null,
        doseLogLocal: DoseLogLocalDatasource(),
        doseLogRemote: null,
        familyLocal: FamilyLocalDatasource(),
        familyRemote: null,
        isOnline: () => true,
        currentUserId: () => 'user-a',
        onlineStream: const Stream<bool>.empty(),
      );

  int requests = 0;

  @override
  Future<SyncReport?> syncAll() async {
    requests++;
    return null;
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  DateTime clock() => DateTime.now().toUtc();

  /// A container in cloud mode (every remote datasource present) or in
  /// local-only mode (none), with [sync] standing in for the sync service.
  ProviderContainer container({
    required bool cloud,
    required _CountingSyncService sync,
  }) {
    final c = ProviderContainer(
      overrides: [
        syncServiceProvider.overrideWithValue(sync),
        medicationDatasourceProvider.overrideWithValue(
          cloud ? FakeMedicationRemote(clock) : null,
        ),
        treatmentDatasourceProvider.overrideWithValue(
          cloud ? FakeTreatmentRemote(clock) : null,
        ),
        prescriptionDatasourceProvider.overrideWithValue(
          cloud ? FakePrescriptionRemote(clock) : null,
        ),
        doseLogDatasourceProvider.overrideWithValue(
          cloud ? FakeDoseLogRemote(clock) : null,
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// One write through each of the four repositories, each followed by a
  /// check of how many syncs [sync] has been asked for.
  Future<void> writeThroughEachRepository(
    ProviderContainer c,
    _CountingSyncService sync, {
    required int Function(int writes) expected,
  }) async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final dose = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );

    await c
        .read(treatmentRepositoryProvider)
        .addTreatment(
          Treatment(id: 't-new', name: 'Flu', startDate: DateTime(2026, 3, 2)),
        );
    await pumpEventQueue();
    expect(sync.requests, expected(1), reason: 'treatment write');

    await c
        .read(medicationRepositoryProvider)
        .addMedication(
          const Medication(id: 'm-new', name: 'Moment', quantity: 1),
        );
    await pumpEventQueue();
    expect(sync.requests, expected(2), reason: 'medication write');

    await c
        .read(prescriptionRepositoryProvider)
        .deactivatePrescription(seeded.prescriptionId);
    await pumpEventQueue();
    expect(sync.requests, expected(3), reason: 'prescription write');

    await c.read(doseLogRepositoryProvider).markDoseTaken(dose);
    await pumpEventQueue();
    expect(sync.requests, expected(4), reason: 'dose log write');
  }

  test('in cloud mode every repository write asks for one sync', () async {
    final sync = _CountingSyncService();
    final c = container(cloud: true, sync: sync);

    await writeThroughEachRepository(c, sync, expected: (writes) => writes);
  });

  test('in local-only mode no repository write asks for a sync', () async {
    final sync = _CountingSyncService();
    final c = container(cloud: false, sync: sync);

    await writeThroughEachRepository(c, sync, expected: (_) => 0);
  });
}
