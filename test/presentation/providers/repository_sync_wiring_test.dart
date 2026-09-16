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

  /// A container whose remote datasources exist only for the tables in
  /// [remotes] (all four: cloud mode; none: local-only mode), with [sync]
  /// standing in for the sync service.
  ProviderContainer container({
    required Set<String> remotes,
    required _CountingSyncService sync,
  }) {
    final c = ProviderContainer(
      overrides: [
        syncServiceProvider.overrideWithValue(sync),
        medicationDatasourceProvider.overrideWithValue(
          remotes.contains('medications') ? FakeMedicationRemote(clock) : null,
        ),
        treatmentDatasourceProvider.overrideWithValue(
          remotes.contains('treatments') ? FakeTreatmentRemote(clock) : null,
        ),
        prescriptionDatasourceProvider.overrideWithValue(
          remotes.contains('prescriptions')
              ? FakePrescriptionRemote(clock)
              : null,
        ),
        doseLogDatasourceProvider.overrideWithValue(
          remotes.contains('dose_logs') ? FakeDoseLogRemote(clock) : null,
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  const tables = ['treatments', 'medications', 'prescriptions', 'dose_logs'];

  /// One write through each of the four repositories, in the order of
  /// [tables]; returns, per table, how many syncs that write asked for.
  Future<Map<String, int>> writeThroughEachRepository(
    ProviderContainer c,
    _CountingSyncService sync,
  ) async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final dose = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );
    final asked = <String, int>{};
    Future<void> step(String table, Future<void> Function() write) async {
      final before = sync.requests;
      await write();
      await pumpEventQueue();
      asked[table] = sync.requests - before;
    }

    await step(
      'treatments',
      () => c
          .read(treatmentRepositoryProvider)
          .addTreatment(
            Treatment(
              id: 't-new',
              name: 'Flu',
              startDate: DateTime(2026, 3, 2),
            ),
          ),
    );
    await step(
      'medications',
      () => c
          .read(medicationRepositoryProvider)
          .addMedication(
            const Medication(id: 'm-new', name: 'Moment', quantity: 1),
          ),
    );
    await step(
      'prescriptions',
      () => c
          .read(prescriptionRepositoryProvider)
          .deactivatePrescription(seeded.prescriptionId),
    );
    await step(
      'dose_logs',
      () => c.read(doseLogRepositoryProvider).markDoseTaken(dose),
    );
    return asked;
  }

  test('in cloud mode every repository write asks for one sync', () async {
    final sync = _CountingSyncService();
    final c = container(remotes: tables.toSet(), sync: sync);

    expect(await writeThroughEachRepository(c, sync), {
      for (final t in tables) t: 1,
    });
  });

  test('in local-only mode no repository write asks for a sync', () async {
    final sync = _CountingSyncService();
    final c = container(remotes: const {}, sync: sync);

    expect(await writeThroughEachRepository(c, sync), {
      for (final t in tables) t: 0,
    });
  });

  // Each repository looks at its own table's remote datasource, not at
  // another table's.
  for (final table in tables) {
    test('only the $table remote: only its writes ask for a sync', () async {
      final sync = _CountingSyncService();
      final c = container(remotes: {table}, sync: sync);

      expect(await writeThroughEachRepository(c, sync), {
        for (final t in tables) t: t == table ? 1 : 0,
      });
    });

    test('every remote but $table: its writes ask for none', () async {
      final sync = _CountingSyncService();
      final c = container(remotes: {...tables}..remove(table), sync: sync);

      expect(await writeThroughEachRepository(c, sync), {
        for (final t in tables) t: t == table ? 0 : 1,
      });
    });
  }
}
