/// Medora - Treatment Entity
///
/// Core domain entity representing an illness/treatment plan.
library;

import 'package:medora/core/clock.dart';

class Treatment {
  const Treatment({
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
    this.sickLeaveFrom,
    this.sickLeaveTo,
    this.sickLeaveRef,
    this.doctor,
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

  /// First day unable to work (date only). Null when no sick leave was
  /// recorded: an ordinary therapy simply leaves these empty.
  final DateTime? sickLeaveFrom;

  /// Last day unable to work (date only); null while the leave is open.
  final DateTime? sickLeaveTo;

  /// Certificate / protocol number (IT: numero di protocollo).
  final String? sickLeaveRef;

  /// Free text, e.g. "Dr. Rossi, Bolzano".
  final String? doctor;

  /// Backward-compatible getters.
  String? get patientName =>
      patientTags.isNotEmpty ? patientTags.join(', ') : null;
  String? get symptoms =>
      symptomTags.isNotEmpty ? symptomTags.join(', ') : null;

  /// Duration of the treatment in days.
  int? get durationDays {
    if (endDate == null) return null;
    return endDate!.difference(startDate).inDays;
  }

  bool get hasSickLeave => sickLeaveFrom != null;

  bool get isSickLeaveOpen => sickLeaveFrom != null && sickLeaveTo == null;

  /// Inclusive calendar days of sick leave; null when none is recorded.
  ///
  /// An open leave counts up to [now]. Inclusive (+1) because a sick note
  /// "from Monday to Friday" means five days, not four.
  int? sickLeaveDaysAt(DateTime now) => sickLeaveFrom == null
      ? null
      : calendarDaysBetween(sickLeaveFrom!, sickLeaveTo ?? now) + 1;

  Treatment copyWith({
    String? id,
    String? userId,
    String? name,
    List<String>? patientTags,
    List<String>? symptomTags,
    DateTime? startDate,
    DateTime? endDate,
    bool? isActive,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? sickLeaveFrom,
    DateTime? sickLeaveTo,
    String? sickLeaveRef,
    String? doctor,
  }) {
    return Treatment(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      patientTags: patientTags ?? this.patientTags,
      symptomTags: symptomTags ?? this.symptomTags,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      isActive: isActive ?? this.isActive,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sickLeaveFrom: sickLeaveFrom ?? this.sickLeaveFrom,
      sickLeaveTo: sickLeaveTo ?? this.sickLeaveTo,
      sickLeaveRef: sickLeaveRef ?? this.sickLeaveRef,
      doctor: doctor ?? this.doctor,
    );
  }
}
