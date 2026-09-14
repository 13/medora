import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

void main() {
  final deleted = DateTime.utc(2026, 3, 4, 10);

  test(
    'medication deleted_at survives toJson/fromJson and is UTC on the wire',
    () {
      final m = MedicationModel(
        id: 'm',
        name: 'x',
        quantity: 1,
        deletedAt: deleted,
      );
      final json = m.toJson();
      expect(json['deleted_at'], '2026-03-04T10:00:00.000Z');
      expect(MedicationModel.fromJson(json).deletedAt?.toUtc(), deleted);
      expect(
        MedicationModel.fromJson({...json, 'deleted_at': null}).deletedAt,
        isNull,
      );
    },
  );

  test('treatment, prescription and dose log carry deleted_at', () {
    final t = TreatmentModel(
      id: 't',
      name: 'x',
      startDate: DateTime(2026, 3),
      deletedAt: deleted,
    );
    expect(TreatmentModel.fromJson(t.toJson()).deletedAt?.toUtc(), deleted);
    final p = PrescriptionModel(
      id: 'p',
      treatmentId: 't',
      medicationId: 'm',
      dosage: '1',
      startTime: DateTime(2026, 3, 1, 8),
      deletedAt: deleted,
    );
    expect(PrescriptionModel.fromJson(p.toJson()).deletedAt?.toUtc(), deleted);
    final d = DoseLogModel(
      id: 'd',
      prescriptionId: 'p',
      scheduledTime: DateTime(2026, 3, 1, 8),
      deletedAt: deleted,
    );
    expect(DoseLogModel.fromJson(d.toJson()).deletedAt?.toUtc(), deleted);
  });

  test('dose log wire timestamps are UTC', () {
    final d = DoseLogModel(
      id: 'd',
      prescriptionId: 'p',
      scheduledTime: DateTime(2026, 3, 1, 8),
      takenTime: DateTime(2026, 3, 1, 8, 5),
    );
    final json = d.toJson();
    expect(json['scheduled_time'] as String, endsWith('Z'));
    expect(json['taken_time'] as String, endsWith('Z'));
    expect(DoseLogModel.fromJson(json).scheduledTime, DateTime(2026, 3, 1, 8));
  });
}
