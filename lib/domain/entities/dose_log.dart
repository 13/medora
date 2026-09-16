/// Medora - Dose Log Entity
///
/// Tracks each scheduled medication dose and its status.
library;

import 'package:medora/core/clock.dart';

/// Possible statuses for a dose.
enum DoseStatus {
  pending,
  taken,
  skipped,
  missed;

  /// Convert from database string.
  static DoseStatus fromString(String value) {
    return DoseStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => DoseStatus.pending,
    );
  }
}

class DoseLog {
  const DoseLog({
    required this.id,
    required this.prescriptionId,
    required this.scheduledTime,
    this.takenTime,
    this.status = DoseStatus.pending,
    this.notes,
    this.createdAt,
    this.updatedAt,
    // Optional joined fields
    this.medicationName,
    this.dosage,
    this.dosageAmount,
    this.dosageUnit,
    this.medicationUnit,
    this.patientTags = const [],
    this.treatmentName,
    this.prescriptionNotes,
    this.asNeeded = false,
  });

  final String id;
  final String prescriptionId;
  final DateTime scheduledTime;
  final DateTime? takenTime;
  final DoseStatus status;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // Optional joined fields for display
  final String? medicationName;

  /// Legacy free-text dosage string (e.g. "20 Tropfen").
  final String? dosage;

  /// Numeric dosage amount from prescription (e.g. 1.5).
  final double? dosageAmount;

  /// Unit override from prescription (e.g. "pills").
  final String? dosageUnit;

  /// Default unit from the medication entity (e.g. "tablets").
  final String? medicationUnit;

  final List<String> patientTags;
  final String? treatmentName;
  final String? prescriptionNotes;

  /// True when the dose belongs to an as-needed prescription: a record of an
  /// intake, not a dose that was scheduled.
  final bool asNeeded;

  /// Formatted dosage: prefers amount+unit, falls back to free-text dosage.
  String? get displayDosage {
    if (dosageAmount != null) {
      final amount = dosageAmount! % 1 == 0
          ? dosageAmount!.toInt().toString()
          : dosageAmount!.toString();
      final unit = (dosageUnit != null && dosageUnit!.isNotEmpty)
          ? dosageUnit
          : ((medicationUnit != null && medicationUnit!.isNotEmpty)
                ? medicationUnit
                : null);
      if (unit != null) return '$amount $unit';
      // No unit — fall back to raw dosage text (e.g. "20 Tropfen")
      return (dosage != null && dosage!.isNotEmpty) ? dosage : amount;
    }
    return dosage;
  }

  /// Returns true if this dose was overdue at [now] (pending and past its
  /// scheduled time).
  bool isOverdueAt(DateTime now) =>
      status == DoseStatus.pending && scheduledTime.isBefore(now);

  /// Returns true if this dose is overdue, per the system clock.
  /// Prefer [isOverdueAt] wherever a clock is available.
  bool get isOverdue => isOverdueAt(systemNow());

  DoseLog copyWith({
    String? id,
    String? prescriptionId,
    DateTime? scheduledTime,
    DateTime? takenTime,
    DoseStatus? status,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? medicationName,
    String? dosage,
    double? dosageAmount,
    String? dosageUnit,
    String? medicationUnit,
    List<String>? patientTags,
    String? treatmentName,
    String? prescriptionNotes,
    bool? asNeeded,
  }) {
    return DoseLog(
      id: id ?? this.id,
      prescriptionId: prescriptionId ?? this.prescriptionId,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      takenTime: takenTime ?? this.takenTime,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      medicationName: medicationName ?? this.medicationName,
      dosage: dosage ?? this.dosage,
      dosageAmount: dosageAmount ?? this.dosageAmount,
      dosageUnit: dosageUnit ?? this.dosageUnit,
      medicationUnit: medicationUnit ?? this.medicationUnit,
      patientTags: patientTags ?? this.patientTags,
      treatmentName: treatmentName ?? this.treatmentName,
      prescriptionNotes: prescriptionNotes ?? this.prescriptionNotes,
      asNeeded: asNeeded ?? this.asNeeded,
    );
  }
}
