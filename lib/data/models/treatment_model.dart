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
    this.createdAt,
    this.updatedAt,
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
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory TreatmentModel.fromJson(Map<String, dynamic> json) {
    return TreatmentModel(
      id: json['id'] as String,
      userId: json['user_id'] as String?,
      name: json['name'] as String,
      patientTags: MedicationModel.parseTags(
          json['patient_tags'] ?? json['patient_name']),
      symptomTags: MedicationModel.parseTags(json['symptom_tags'] ?? json['symptoms']),
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
      isActive: json['is_active'] as bool? ?? true,
      notes: json['notes'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
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
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
    );
  }
}
