import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/treatment.dart';

void main() {
  final treatment = Treatment(
    id: 't1',
    name: 'Stirnhöhlenentzündung',
    startDate: DateTime(2026, 3, 2),
    endDate: DateTime(2026, 3, 11),
    sickLeaveFrom: DateTime(2026, 3, 3),
    sickLeaveTo: DateTime(2026, 3, 9),
    sickLeaveRef: '1234567890',
    doctor: 'Dr. Rossi, Bozen',
  );

  test('domain -> model -> domain preserves the sick-leave fields', () {
    final back = TreatmentModel.fromDomain(treatment).toDomain();
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });

  test('toJson writes date-only strings, like start_date', () {
    final json = TreatmentModel.fromDomain(treatment).toJson();
    expect(json['sick_leave_from'], '2026-03-03');
    expect(json['sick_leave_to'], '2026-03-09');
    expect(json['sick_leave_ref'], '1234567890');
    expect(json['doctor'], 'Dr. Rossi, Bozen');
  });

  test('toJson sends explicit nulls when there is no sick leave', () {
    final json = TreatmentModel(
      id: 't2',
      name: 'Vitamin D',
      startDate: DateTime(2026, 3, 2),
    ).toJson();
    // Whole-row upsert: the keys must be present so a cleared value clears
    // the server column too.
    for (final key in [
      'sick_leave_from',
      'sick_leave_to',
      'sick_leave_ref',
      'doctor',
    ]) {
      expect(json.containsKey(key), isTrue, reason: key);
      expect(json[key], isNull, reason: key);
    }
  });

  test('json round-trip keeps the fields', () {
    final json = TreatmentModel.fromDomain(treatment).toJson();
    final back = TreatmentModel.fromJson(json);
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });

  test('a row from before v15 parses with the fields null', () {
    final legacy = TreatmentModel.fromJson({
      'id': 't1',
      'name': 'Influenza',
      'start_date': '2026-03-02',
      'is_active': true,
    });
    expect(legacy.sickLeaveFrom, isNull);
    expect(legacy.sickLeaveTo, isNull);
    expect(legacy.sickLeaveRef, isNull);
    expect(legacy.doctor, isNull);
  });

  test('local map round-trip keeps the fields', () {
    final back = TreatmentModel.fromLocalMap({
      'id': 't1',
      'name': 'Stirnhöhlenentzündung',
      'start_date': '2026-03-02',
      'is_active': 1,
      'sick_leave_from': '2026-03-03',
      'sick_leave_to': '2026-03-09',
      'sick_leave_ref': '1234567890',
      'doctor': 'Dr. Rossi, Bozen',
    });
    expect(back.sickLeaveFrom, DateTime(2026, 3, 3));
    expect(back.sickLeaveTo, DateTime(2026, 3, 9));
    expect(back.sickLeaveRef, '1234567890');
    expect(back.doctor, 'Dr. Rossi, Bozen');
  });
}
