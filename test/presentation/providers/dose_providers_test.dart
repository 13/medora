import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  late ProviderContainer c;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      syncStartupDelayProvider.overrideWithValue(Duration.zero),
      reminderPortProvider.overrideWithValue(FakePort()),
    ]);
  });
  tearDown(() async {
    c.dispose();
    await tearDownTestDatabase();
  });

  test('dosesForDayProvider returns only that day and refreshes on version bump', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, today.add(const Duration(hours: 8)));
    await seedDoseLog(db, s.prescriptionId, tomorrow.add(const Duration(hours: 8)));

    expect((await c.read(dosesForDayProvider(today).future)).map((d) => d.id), [a]);
    expect((await c.read(dosesForDayProvider(tomorrow).future)).length, 1);

    await c.read(doseActionsProvider).take(a);
    final after = await c.read(dosesForDayProvider(today).future);
    expect(after.single.status, DoseStatus.taken);
  });

  test('dayKey normalizes to midnight', () {
    expect(dayKey(DateTime(2026, 3, 5, 17, 42)), DateTime(2026, 3, 5));
  });

  test('nextDueDoseProvider picks the earliest pending within 2h, else the earliest pending', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final soon = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(minutes: 30)));
    await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 5)), status: 'taken');
    await c.read(todaysDoseLogsProvider.future);
    expect(c.read(nextDueDoseProvider)?.id, soon);

    await c.read(doseActionsProvider).take(soon);
    await c.read(todaysDoseLogsProvider.future);
    expect(c.read(nextDueDoseProvider), isNull);
  });

  test('takeAllDue marks each id taken and returns the taken ids', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 2)));
    final b = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 1)));
    final taken = await c.read(doseActionsProvider).takeAllDue([a, b]);
    expect(taken.length, 2);
    expect(taken, containsAll([a, b]));
    final doses = await c.read(dosesForDayProvider(today).future);
    expect(doses.where((d) => d.status == DoseStatus.taken).length, 2);
  });

  test('takeAllDue skips ids that are not pending and does not double-count or double-diminish them', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await db.update('prescriptions', {'auto_diminish': 1},
        where: 'id = ?', whereArgs: [s.prescriptionId]);
    final a = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 2)));
    final b = await seedDoseLog(db, s.prescriptionId, now.subtract(const Duration(hours: 1)));
    final alreadyTaken = await seedDoseLog(
        db, s.prescriptionId, now.subtract(const Duration(hours: 3)),
        status: 'taken');

    final taken = await c.read(doseActionsProvider).takeAllDue([a, b, alreadyTaken]);
    expect(taken.length, 2);
    expect(taken, isNot(contains(alreadyTaken)));

    final med = await db.query('medications',
        where: 'id = ?', whereArgs: [s.medicationId]);
    expect(med.single['quantity'], 8);
  });

  test('take returns false for an unknown id', () async {
    final result = await c.read(doseActionsProvider).take('does-not-exist');
    expect(result, isFalse);
  });

  test('dosesForDayProvider hides pending doses of inactive prescriptions but keeps taken ones', () async {
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);
    final s2 = await seedPrescription(db);
    await db.update('prescriptions', {'is_active': 0},
        where: 'id = ?', whereArgs: [s2.prescriptionId]);
    final pending = await seedDoseLog(
        db, s2.prescriptionId, today.add(const Duration(hours: 9)));
    final taken = await seedDoseLog(
        db, s2.prescriptionId, today.add(const Duration(hours: 10)),
        status: 'taken');

    final doses = await c.read(dosesForDayProvider(today).future);
    expect(doses.map((d) => d.id), [taken]);
    expect(doses.any((d) => d.id == pending), isFalse);
  });

  test('undoTake restores pending and clears takenTime', () async {
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final a = await seedDoseLog(db, s.prescriptionId, now.add(const Duration(hours: 1)));
    final actions = c.read(doseActionsProvider);
    await actions.take(a);
    await actions.undoTake(a);
    final dose = (await c.read(dosesForDayProvider(today).future)).single;
    expect(dose.status, DoseStatus.pending);
    expect(dose.takenTime, isNull);
  });
}
