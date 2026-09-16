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

  group('copyWith', () {
    final full = TreatmentModel(
      id: 't1',
      userId: 'user-a',
      name: 'Stirnhöhlenentzündung',
      patientTags: const ['Ben'],
      symptomTags: const ['Kopfschmerzen'],
      startDate: DateTime(2026, 3, 2),
      endDate: DateTime(2026, 3, 11),
      isActive: false,
      notes: 'ging langsam weg',
      sickLeaveFrom: DateTime(2026, 3, 3),
      sickLeaveTo: DateTime(2026, 3, 9),
      sickLeaveRef: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
      createdAt: DateTime(2026, 3, 2, 8),
      updatedAt: DateTime(2026, 3, 11, 8),
      deletedAt: DateTime(2026, 3, 12, 8),
    );

    Map<String, Object?> fields(TreatmentModel m) => {
      'id': m.id,
      'userId': m.userId,
      'name': m.name,
      'patientTags': m.patientTags,
      'symptomTags': m.symptomTags,
      'startDate': m.startDate,
      'endDate': m.endDate,
      'isActive': m.isActive,
      'notes': m.notes,
      'sickLeaveFrom': m.sickLeaveFrom,
      'sickLeaveTo': m.sickLeaveTo,
      'sickLeaveRef': m.sickLeaveRef,
      'doctor': m.doctor,
      'createdAt': m.createdAt,
      'updatedAt': m.updatedAt,
      'deletedAt': m.deletedAt,
    };

    test('with no arguments keeps every field', () {
      expect(fields(full.copyWith()), fields(full));
    });

    test('replaces every field it is given', () {
      final other = TreatmentModel(
        id: 't2',
        userId: 'user-b',
        name: 'Grippe',
        patientTags: const ['Anna'],
        symptomTags: const ['Fieber'],
        startDate: DateTime(2026, 1, 31),
        endDate: DateTime(2026, 2, 9),
        notes: 'Bettruhe',
        sickLeaveFrom: DateTime(2026, 2, 2),
        sickLeaveTo: DateTime(2026, 2, 5),
        sickLeaveRef: 'AB-42',
        doctor: 'Dr. Bianchi',
        createdAt: DateTime(2026, 2, 1, 8),
        updatedAt: DateTime(2026, 2, 9, 8),
        deletedAt: DateTime(2026, 2, 10, 8),
      );
      final copied = full.copyWith(
        id: other.id,
        userId: other.userId,
        name: other.name,
        patientTags: other.patientTags,
        symptomTags: other.symptomTags,
        startDate: other.startDate,
        endDate: other.endDate,
        isActive: other.isActive,
        notes: other.notes,
        sickLeaveFrom: other.sickLeaveFrom,
        sickLeaveTo: other.sickLeaveTo,
        sickLeaveRef: other.sickLeaveRef,
        doctor: other.doctor,
        createdAt: other.createdAt,
        updatedAt: other.updatedAt,
        deletedAt: other.deletedAt,
      );
      expect(fields(copied), fields(other));
    });
  });
}
