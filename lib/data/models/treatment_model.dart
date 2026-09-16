/// Medora - Treatment Model
library;

import 'dart:convert';

import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/treatment.dart';

class TreatmentModel {
  const TreatmentModel({
    required this.id,
    this.userId,
    required this.name,
    this.patientTags = const [],
    this.symptomTags = const [],
    required this.startDate,
    this.endDate,
    this.isActive = true,
    this.notes,
    this.sickLeaveFrom,
    this.sickLeaveTo,
    this.sickLeaveRef,
    this.doctor,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String name;
  final List<String> patientTags;
  final List<String> symptomTags;
  final DateTime startDate;
  final DateTime? endDate;
  final bool isActive;
  final String? notes;

  /// First day of certified sick leave (date only).
  final DateTime? sickLeaveFrom;

  /// Last day of certified sick leave (date only); null while it is open.
  final DateTime? sickLeaveTo;

  /// Sick-note / certificate number.
  final String? sickLeaveRef;

  /// The doctor who certified the leave.
  final String? doctor;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Tombstone: non-null when the row is deleted (spec §4.6).
  final DateTime? deletedAt;

  factory TreatmentModel.fromJson(Map<String, dynamic> json) {
    return TreatmentModel(
      id: json['id'] as String,
      userId: json['user_id'] as String?,
      name: json['name'] as String,
      patientTags: MedicationModel.parseTags(
        json['patient_tags'] ?? json['patient_name'],
      ),
      symptomTags: MedicationModel.parseTags(
        json['symptom_tags'] ?? json['symptoms'],
      ),
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
      isActive: json['is_active'] == true || json['is_active'] == 1,
      notes: json['notes'] as String?,
      sickLeaveFrom: json['sick_leave_from'] != null
          ? DateTime.tryParse(json['sick_leave_from'] as String)
          : null,
      sickLeaveTo: json['sick_leave_to'] != null
          ? DateTime.tryParse(json['sick_leave_to'] as String)
          : null,
      sickLeaveRef: json['sick_leave_ref'] as String?,
      doctor: json['doctor'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      deletedAt: json['deleted_at'] != null
          ? DateTime.parse(json['deleted_at'] as String)
          : null,
    );
  }

  /// Create from local SQLite row.
  factory TreatmentModel.fromLocalMap(Map<String, dynamic> map) {
    return TreatmentModel(
      id: map['id'] as String,
      userId: map['user_id'] as String?,
      name: map['name'] as String,
      patientTags: MedicationModel.parseTags(map['patient_tags']),
      symptomTags: MedicationModel.parseTags(map['symptom_tags']),
      startDate: DateTime.parse(map['start_date'] as String),
      endDate: map['end_date'] != null
          ? DateTime.tryParse(map['end_date'] as String)
          : null,
      isActive: (map['is_active'] as int? ?? 1) == 1,
      notes: map['notes'] as String?,
      sickLeaveFrom: map['sick_leave_from'] != null
          ? DateTime.tryParse(map['sick_leave_from'] as String)
          : null,
      sickLeaveTo: map['sick_leave_to'] != null
          ? DateTime.tryParse(map['sick_leave_to'] as String)
          : null,
      sickLeaveRef: map['sick_leave_ref'] as String?,
      doctor: map['doctor'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
      deletedAt: map['deleted_at'] != null
          ? DateTime.tryParse(map['deleted_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'patient_tags': jsonEncode(patientTags),
      'symptom_tags': jsonEncode(symptomTags),
      'start_date': startDate.toIso8601String().split('T').first,
      'end_date': endDate?.toIso8601String().split('T').first,
      'is_active': isActive,
      'notes': notes,
      'sick_leave_from': sickLeaveFrom?.toIso8601String().split('T').first,
      'sick_leave_to': sickLeaveTo?.toIso8601String().split('T').first,
      'sick_leave_ref': sickLeaveRef,
      'doctor': doctor,
      'updated_at': updatedAt?.toUtc().toIso8601String(),
      if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
    };
  }

  Treatment toDomain() {
    return Treatment(
      id: id,
      userId: userId,
      name: name,
      patientTags: patientTags,
      symptomTags: symptomTags,
      startDate: startDate,
      endDate: endDate,
      isActive: isActive,
      notes: notes,
      sickLeaveFrom: sickLeaveFrom,
      sickLeaveTo: sickLeaveTo,
      sickLeaveRef: sickLeaveRef,
      doctor: doctor,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  factory TreatmentModel.fromDomain(Treatment entity) {
    return TreatmentModel(
      id: entity.id,
      userId: entity.userId,
      name: entity.name,
      patientTags: entity.patientTags,
      symptomTags: entity.symptomTags,
      startDate: entity.startDate,
      endDate: entity.endDate,
      isActive: entity.isActive,
      notes: entity.notes,
      sickLeaveFrom: entity.sickLeaveFrom,
      sickLeaveTo: entity.sickLeaveTo,
      sickLeaveRef: entity.sickLeaveRef,
      doctor: entity.doctor,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
    );
  }

  /// Field-preserving copy. Use this instead of rebuilding the model by
  /// hand: a hand-rolled rebuild silently drops every field the author
  /// forgot, which is how the sick-leave columns were lost on "End".
  ///
  /// Note the codebase-wide `??` convention: passing null keeps the current
  /// value, it does not clear the field. Clear a field by constructing a
  /// new [TreatmentModel].
  TreatmentModel copyWith({
    String? id,
    String? userId,
    String? name,
    List<String>? patientTags,
    List<String>? symptomTags,
    DateTime? startDate,
    DateTime? endDate,
    bool? isActive,
    String? notes,
    DateTime? sickLeaveFrom,
    DateTime? sickLeaveTo,
    String? sickLeaveRef,
    String? doctor,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return TreatmentModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      patientTags: patientTags ?? this.patientTags,
      symptomTags: symptomTags ?? this.symptomTags,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isActive: isActive ?? this.isActive,
      notes: notes ?? this.notes,
      sickLeaveFrom: sickLeaveFrom ?? this.sickLeaveFrom,
      sickLeaveTo: sickLeaveTo ?? this.sickLeaveTo,
      sickLeaveRef: sickLeaveRef ?? this.sickLeaveRef,
      doctor: doctor ?? this.doctor,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
