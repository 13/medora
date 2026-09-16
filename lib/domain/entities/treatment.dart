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

  /// Inclusive calendar days of sick leave, always 1 or more, or null.
  ///
  /// An open leave counts up to [now]; a closed leave ignores [now]. Only
  /// the calendar date of each value matters, never the time of day.
  /// Inclusive (+1) because a sick note "from Monday to Friday" means five
  /// days, not four, and a leave starting today is day 1.
  ///
  /// Null means "show no count". That is the case when:
  /// - no leave is recorded ([hasSickLeave] is false);
  /// - the leave ends on a day before it starts (an invalid range, e.g.
  ///   from a synced or restored row the form never validated);
  /// - an open leave starts after [now] (it has not begun yet).
  ///
  /// A null count can therefore occur while [hasSickLeave] is true, so
  /// callers must not force-unwrap it.
  int? sickLeaveDaysAt(DateTime now) {
    final from = sickLeaveFrom;
    if (from == null) return null;
    final span = calendarDaysBetween(from, sickLeaveTo ?? now);
    return span < 0 ? null : span + 1;
  }

  /// The `sickLeaveTo` to store when the leave is ended at [now], or null
  /// when there is nothing to end.
  ///
  /// An open leave ends on the calendar date of [now] (date only, like
  /// every sick-leave date). Null when:
  /// - no leave is recorded;
  /// - the leave is already closed: a closed leave is never moved;
  /// - the open leave starts after [now]'s date. Ending it "today" would
  ///   put its end before its start, and clamping to the start would
  ///   invent a day off that has not happened, so it stays open for the
  ///   user to edit or remove.
  ///
  /// A leave that started today therefore ends today, never earlier.
  DateTime? sickLeaveEndAt(DateTime now) {
    final from = sickLeaveFrom;
    if (from == null || sickLeaveTo != null) return null;
    if (calendarDaysBetween(from, now) < 0) return null;
    return DateTime(now.year, now.month, now.day);
  }

  /// A copy with the given fields replaced. A null argument keeps the
  /// current value, so a field cannot be cleared here; build a new
  /// [Treatment] for that.
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
