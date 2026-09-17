/// The repository providers hand every repository the injected clock
/// (`nowProvider`), so a write stamps the time the app is told it is, not
/// the wall clock.
///
/// The local datasources under them keep the wall clock: the dose views and
/// the overdue sweep read "today" from it, which the widget suites rely on
/// (see `home_dashboard_test.dart`). A datasource never stamps an edit time
/// later than its own clock, so the injected time is kept only while it is
/// not ahead of the wall clock; [fixed] is in the past for that reason.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  // Years before the wall clock, so a stamp taken from it cannot pass.
  final fixed = DateTime(2021, 5, 6, 7, 8, 9);
  final fixedUtc = fixed.toUtc().toIso8601String();

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        nowProvider.overrideWithValue(() => fixed),
        // Local-only: no remote, so no write asks for a sync.
        medicationDatasourceProvider.overrideWithValue(null),
        treatmentDatasourceProvider.overrideWithValue(null),
        prescriptionDatasourceProvider.overrideWithValue(null),
        doseLogDatasourceProvider.overrideWithValue(null),
        familyDatasourceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<Map<String, Object?>> row(String table, String id) async =>
      (await (await AppDatabase.instance.database).query(
        table,
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('a new medication is stamped with the injected clock', () async {
    final c = container();
    await c
        .read(medicationRepositoryProvider)
        .addMedication(const Medication(id: 'm1', name: 'Moment', quantity: 5));
    final m = await row('medications', 'm1');
    expect(DateTime.parse(m['updated_at']! as String), fixed);
    expect(DateTime.parse(m['created_at']! as String), fixed);
    expect(m['edited_at'], fixedUtc);

    // An edit on the same stopped clock: just past the stored stamp.
    await c
        .read(medicationRepositoryProvider)
        .updateMedication(
          const Medication(id: 'm1', name: 'Moment 2', quantity: 5),
        );
    final edited = await row('medications', 'm1');
    expect(
      DateTime.parse(edited['updated_at']! as String),
      fixed.add(const Duration(milliseconds: 1)),
    );
  });

  test('new treatments and prescriptions take the injected '
      'clock', () async {
    final c = container();
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await c
        .read(treatmentRepositoryProvider)
        .addTreatment(
          Treatment(id: 't1', name: 'Flu', startDate: DateTime(2021, 5, 6)),
        );
    expect((await row('treatments', 't1'))['edited_at'], fixedUtc);

    await c
        .read(prescriptionRepositoryProvider)
        .addPrescription(
          Prescription(
            id: 'p1',
            treatmentId: seeded.treatmentId,
            medicationId: seeded.medicationId,
            dosage: '1',
            startTime: DateTime(2021, 5, 6, 8),
          ),
        );
    final p = await row('prescriptions', 'p1');
    expect(DateTime.parse(p['created_at']! as String), fixed);
    expect(p['edited_at'], fixedUtc);
  });

  test('a dose taken, and doses generated, take the injected clock', () async {
    final c = container();
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db, durationDays: 1);
    final dose = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );

    await c.read(doseLogRepositoryProvider).markDoseTaken(dose);
    final taken = await row('dose_logs', dose);
    expect(DateTime.parse(taken['taken_time']! as String), fixed);

    await c
        .read(doseLogRepositoryProvider)
        .generateDoseLogsForPrescription(seeded.prescriptionId);
    final generated = await db.query(
      'dose_logs',
      where: 'prescription_id = ? AND id != ?',
      whereArgs: [seeded.prescriptionId, dose],
    );
    expect(generated, isNotEmpty);
    for (final g in generated) {
      expect(DateTime.parse(g['created_at']! as String), fixed);
    }
  });

  test('a family made here takes the injected clock', () async {
    final c = container();
    final family =
        (await c.read(familyRepositoryProvider).createFamily('Home', 'Ben'))
            .dataOrNull!;
    final f = await row('families', family.id);
    expect(DateTime.parse(f['created_at']! as String), fixed);
    final members = await (await AppDatabase.instance.database).query(
      'family_members',
      where: 'family_id = ?',
      whereArgs: [family.id],
    );
    expect(DateTime.parse(members.single['joined_at']! as String), fixed);
  });
}
