/// Medora - Prescription Model
library;

import 'dart:convert';
import 'package:medora/domain/entities/prescription.dart';

class PrescriptionModel {
  const PrescriptionModel({
    required this.id,
    required this.treatmentId,
    required this.medicationId,
    required this.dosage,
    this.dosageAmount,
    this.dosageUnit,
    this.intervalHours = 8,
    this.durationDays = 7,
    required this.startTime,
    this.isActive = true,
    this.autoDiminish = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.scheduleType = 'fixed_interval',
    this.scheduleTimes,
    this.medicationName,
    this.treatmentName,
  });

  final String id;
  final String treatmentId;
  final String medicationId;
  final String dosage;
  final double? dosageAmount;
  final String? dosageUnit;
  final int intervalHours;
  final int durationDays;
  final DateTime startTime;
  final bool isActive;
  final bool autoDiminish;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String scheduleType;
  final List<String>? scheduleTimes;
  final String? medicationName;
  final String? treatmentName;

  factory PrescriptionModel.fromJson(Map<String, dynamic> json) {
    final medication = json['medications'] as Map<String, dynamic>?;
    final treatment = json['treatments'] as Map<String, dynamic>?;

    // Parse schedule_times from JSON string or list
    List<String>? parsedTimes;
    final rawTimes = json['schedule_times'];
    if (rawTimes is String && rawTimes.isNotEmpty) {
      parsedTimes = (jsonDecode(rawTimes) as List).cast<String>();
    } else if (rawTimes is List) {
      parsedTimes = rawTimes.cast<String>();
    }

    return PrescriptionModel(
      id: json['id'] as String,
      treatmentId: json['treatment_id'] as String,
      medicationId: json['medication_id'] as String,
      dosage: json['dosage'] as String,
      dosageAmount: (json['dosage_amount'] as num?)?.toDouble(),
      dosageUnit: json['dosage_unit'] as String?,
      intervalHours: json['interval_hours'] as int? ?? 8,
      durationDays: json['duration_days'] as int? ?? 7,
      startTime: DateTime.parse(json['start_time'] as String),
      isActive: json['is_active'] as bool? ?? true,
      autoDiminish: json['auto_diminish'] == true || json['auto_diminish'] == 1,
      notes: json['notes'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      scheduleType: json['schedule_type'] as String? ?? 'fixed_interval',
      scheduleTimes: parsedTimes,
      medicationName: medication?['name'] as String?,
      treatmentName: treatment?['name'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'treatment_id': treatmentId,
      'medication_id': medicationId,
      'dosage': dosage,
      'dosage_amount': dosageAmount,
      'dosage_unit': dosageUnit,
      'interval_hours': intervalHours,
      'duration_days': durationDays,
      'start_time': startTime.toIso8601String(),
      'is_active': isActive,
      'auto_diminish': autoDiminish,
      'notes': notes,
      'schedule_type': scheduleType,
      'schedule_times':
          scheduleTimes != null ? jsonEncode(scheduleTimes) : null,
    };
  }

  /// Convert from local SQLite map.
  factory PrescriptionModel.fromLocalMap(Map<String, dynamic> map) {
    List<String>? parsedTimes;
    final rawTimes = map['schedule_times'];
    if (rawTimes is String && rawTimes.isNotEmpty) {
      parsedTimes = (jsonDecode(rawTimes) as List).cast<String>();
    }

    return PrescriptionModel(
      id: map['id'] as String,
      treatmentId: map['treatment_id'] as String,
      medicationId: map['medication_id'] as String,
      dosage: map['dosage'] as String,
      dosageAmount: (map['dosage_amount'] as num?)?.toDouble(),
      dosageUnit: map['dosage_unit'] as String?,
      intervalHours: map['interval_hours'] as int? ?? 8,
      durationDays: map['duration_days'] as int? ?? 7,
      startTime: DateTime.parse(map['start_time'] as String),
      isActive: (map['is_active'] as int? ?? 1) == 1,
      autoDiminish: (map['auto_diminish'] as int? ?? 0) == 1,
      notes: map['notes'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
      scheduleType: map['schedule_type'] as String? ?? 'fixed_interval',
      scheduleTimes: parsedTimes,
      medicationName: map['medication_name'] as String?,
      treatmentName: map['treatment_name'] as String?,
    );
  }

  /// Convert to local SQLite map.
  Map<String, dynamic> toLocalMap() {
    return {
      'id': id,
      'treatment_id': treatmentId,
      'medication_id': medicationId,
      'dosage': dosage,
      'dosage_amount': dosageAmount,
      'dosage_unit': dosageUnit,
      'interval_hours': intervalHours,
      'duration_days': durationDays,
      'start_time': startTime.toIso8601String(),
      'is_active': isActive ? 1 : 0,
      'auto_diminish': autoDiminish ? 1 : 0,
      'notes': notes,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'schedule_type': scheduleType,
      'schedule_times':
          scheduleTimes != null ? jsonEncode(scheduleTimes) : null,
    };
  }

  Prescription toDomain() {
    return Prescription(
      id: id,
      treatmentId: treatmentId,
      medicationId: medicationId,
      dosage: dosage,
      dosageAmount: dosageAmount,
      dosageUnit: dosageUnit,
      intervalHours: intervalHours,
      durationDays: durationDays,
      startTime: startTime,
      isActive: isActive,
      autoDiminish: autoDiminish,
      notes: notes,
      createdAt: createdAt,
      updatedAt: updatedAt,
      scheduleType: scheduleType,
      scheduleTimes: scheduleTimes,
      medicationName: medicationName,
      treatmentName: treatmentName,
    );
  }

  factory PrescriptionModel.fromDomain(Prescription entity) {
    return PrescriptionModel(
      id: entity.id,
      treatmentId: entity.treatmentId,
      medicationId: entity.medicationId,
      dosage: entity.dosage,
      dosageAmount: entity.dosageAmount,
      dosageUnit: entity.dosageUnit,
      intervalHours: entity.intervalHours,
      durationDays: entity.durationDays,
      startTime: entity.startTime,
      isActive: entity.isActive,
      autoDiminish: entity.autoDiminish,
      notes: entity.notes,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
      scheduleType: entity.scheduleType,
      scheduleTimes: entity.scheduleTimes,
      medicationName: entity.medicationName,
      treatmentName: entity.treatmentName,
    );
  }
}

