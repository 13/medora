/// Medora - Prescription Entity
///
/// Represents a medication prescription within a treatment plan.
library;

class Prescription {
  const Prescription({
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
    // Joined fields (nullable)
    this.medicationName,
    this.treatmentName,
  });

  final String id;
  final String treatmentId;
  final String medicationId;

  /// Free-text dosage string (legacy / display fallback, e.g. "20 Tropfen").
  final String dosage;

  /// Numeric amount, e.g. 1.5 (tablets), 20 (drops).
  final double? dosageAmount;

  /// Unit override for this prescription, e.g. "pills".
  /// If null, falls back to the medication's quantityUnit or the dosage text.
  final String? dosageUnit;

  final int intervalHours;
  final int durationDays;
  final DateTime startTime;
  final bool isActive;
  final bool autoDiminish;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 'fixed_interval' or 'times_per_day'
  final String scheduleType;

  /// List of time strings like ['08:00', '12:00', '18:00'] for times_per_day
  final List<String>? scheduleTimes;

  // Optional joined fields for display
  final String? medicationName;
  final String? treatmentName;

  /// Formatted dosage string: amount + unit if available, otherwise raw dosage text.
  String displayDosage({String? medicationUnit}) {
    if (dosageAmount != null) {
      final amount = dosageAmount! % 1 == 0
          ? dosageAmount!.toInt().toString()
          : dosageAmount!.toString();
      final unit = dosageUnit ?? medicationUnit;
      if (unit != null && unit.isNotEmpty) return '$amount $unit';
      // No unit at all — fall back to raw dosage text (e.g. "20 Tropfen")
      return dosage.isNotEmpty ? dosage : amount;
    }
    return dosage;
  }

  /// Calculate the end time based on start + duration.
  DateTime get endTime => startTime.add(Duration(days: durationDays));

  /// Number of doses per day.
  int get dosesPerDay {
    if (scheduleType == 'times_per_day' && scheduleTimes != null) {
      return scheduleTimes!.length;
    }
    return (24 / intervalHours).ceil();
  }

  /// Generate all scheduled dose times for this prescription.
  List<DateTime> get scheduledDoseTimes {
    final times = <DateTime>[];
    final end = endTime;

    if (scheduleType == 'times_per_day' && scheduleTimes != null && scheduleTimes!.isNotEmpty) {
      // Generate times for each day at the specified times
      var currentDate = DateTime(startTime.year, startTime.month, startTime.day);
      while (currentDate.isBefore(end)) {
        for (final timeStr in scheduleTimes!) {
          final parts = timeStr.split(':');
          final h = int.tryParse(parts[0]) ?? 8;
          final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final dt = DateTime(currentDate.year, currentDate.month, currentDate.day, h, m);
          if (dt.isAfter(startTime.subtract(const Duration(minutes: 1))) && dt.isBefore(end)) {
            times.add(dt);
          }
        }
        currentDate = currentDate.add(const Duration(days: 1));
      }
    } else {
      // Fixed interval
      var current = startTime;
      while (current.isBefore(end)) {
        times.add(current);
        current = current.add(Duration(hours: intervalHours));
      }
    }

    times.sort();
    return times;
  }

  Prescription copyWith({
    String? id,
    String? treatmentId,
    String? medicationId,
    String? dosage,
    double? dosageAmount,
    String? dosageUnit,
    int? intervalHours,
    int? durationDays,
    DateTime? startTime,
    bool? isActive,
    bool? autoDiminish,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? scheduleType,
    List<String>? scheduleTimes,
    String? medicationName,
    String? treatmentName,
  }) {
    return Prescription(
      id: id ?? this.id,
      treatmentId: treatmentId ?? this.treatmentId,
      medicationId: medicationId ?? this.medicationId,
      dosage: dosage ?? this.dosage,
      dosageAmount: dosageAmount ?? this.dosageAmount,
      dosageUnit: dosageUnit ?? this.dosageUnit,
      intervalHours: intervalHours ?? this.intervalHours,
      durationDays: durationDays ?? this.durationDays,
      startTime: startTime ?? this.startTime,
      isActive: isActive ?? this.isActive,
      autoDiminish: autoDiminish ?? this.autoDiminish,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleTimes: scheduleTimes ?? this.scheduleTimes,
      medicationName: medicationName ?? this.medicationName,
      treatmentName: treatmentName ?? this.treatmentName,
    );
  }
}

