/// Medora - Dose Log Model
library;

import 'package:medora/domain/entities/dose_log.dart';

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
    // Handle joined prescription -> medication data
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
      patientTags:
          (json['patient_tags'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      treatmentName: json['treatment_name'] as String?,
      prescriptionNotes: prescription?['notes'] as String?,
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
      'patient_tags': patientTags,
      'treatment_name': treatmentName,
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

