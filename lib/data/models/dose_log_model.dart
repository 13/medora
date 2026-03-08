/// Medora - Dose Log Model
library;

import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/data/models/medication_model.dart';

class DoseLogModel {
  const DoseLogModel({
    required this.id,
    required this.prescriptionId,
    required this.scheduledTime,
    this.takenTime,
    this.status = DoseStatus.pending,
    this.notes,
    this.createdAt,
    this.medicationName,
    this.dosage,
    this.dosageAmount,
    this.dosageUnit,
    this.medicationUnit,
    this.patientTags = const [],
    this.treatmentName,
    this.prescriptionNotes,
  });

  final String id;
  final String prescriptionId;
  final DateTime scheduledTime;
  final DateTime? takenTime;
  final DoseStatus status;
  final String? notes;
  final DateTime? createdAt;
  final String? medicationName;
  final String? dosage;
  final double? dosageAmount;
  final String? dosageUnit;
  final String? medicationUnit;
  final List<String> patientTags;
  final String? treatmentName;
  final String? prescriptionNotes;

  factory DoseLogModel.fromJson(Map<String, dynamic> json) {
    final prescription = json['prescriptions'] as Map<String, dynamic>?;
    final medication = prescription?['medications'] as Map<String, dynamic>?;

    return DoseLogModel(
      id: json['id'] as String,
      prescriptionId: json['prescription_id'] as String,
      scheduledTime: DateTime.parse(json['scheduled_time'] as String),
      takenTime: json['taken_time'] != null
          ? DateTime.parse(json['taken_time'] as String)
          : null,
      status: DoseStatus.fromString(json['status'] as String? ?? 'pending'),
      notes: json['notes'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      medicationName: medication?['name'] as String?,
      dosage: prescription?['dosage'] as String?,
      patientTags: MedicationModel.parseTags(json['patient_tags']),
      treatmentName: json['treatment_name'] as String?,
      prescriptionNotes: prescription?['notes'] as String?,
    );
  }

  factory DoseLogModel.fromLocalMap(Map<String, dynamic> map) {
    return DoseLogModel(
      id: map['id'] as String,
      prescriptionId: map['prescription_id'] as String,
      scheduledTime: DateTime.parse(map['scheduled_time'] as String),
      takenTime: map['taken_time'] != null
          ? DateTime.tryParse(map['taken_time'] as String)
          : null,
      status: DoseStatus.fromString(map['status'] as String? ?? 'pending'),
      notes: map['notes'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      medicationName: map['medication_name'] as String?,
      dosage: map['dosage'] as String?,
      dosageAmount: (map['dosage_amount'] as num?)?.toDouble(),
      dosageUnit: map['dosage_unit'] as String?,
      medicationUnit: map['medication_unit'] as String?,
      patientTags: MedicationModel.parseTags(map['patient_tags']),
      treatmentName: map['treatment_name'] as String?,
      prescriptionNotes: map['prescription_notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'prescription_id': prescriptionId,
      'scheduled_time': scheduledTime.toIso8601String(),
      'taken_time': takenTime?.toIso8601String(),
      'status': status.name,
      'notes': notes,
    };
  }

  DoseLog toDomain() {
    return DoseLog(
      id: id,
      prescriptionId: prescriptionId,
      scheduledTime: scheduledTime,
      takenTime: takenTime,
      status: status,
      notes: notes,
      createdAt: createdAt,
      medicationName: medicationName,
      dosage: dosage,
      dosageAmount: dosageAmount,
      dosageUnit: dosageUnit,
      medicationUnit: medicationUnit,
      patientTags: patientTags,
      treatmentName: treatmentName,
      prescriptionNotes: prescriptionNotes,
    );
  }

  factory DoseLogModel.fromDomain(DoseLog entity) {
    return DoseLogModel(
      id: entity.id,
      prescriptionId: entity.prescriptionId,
      scheduledTime: entity.scheduledTime,
      takenTime: entity.takenTime,
      status: entity.status,
      notes: entity.notes,
      createdAt: entity.createdAt,
      medicationName: entity.medicationName,
      dosage: entity.dosage,
      dosageAmount: entity.dosageAmount,
      dosageUnit: entity.dosageUnit,
      medicationUnit: entity.medicationUnit,
      patientTags: entity.patientTags,
      treatmentName: entity.treatmentName,
      prescriptionNotes: entity.prescriptionNotes,
    );
  }
}
