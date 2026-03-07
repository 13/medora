/// Medora - Treatment Entity
///
/// Core domain entity representing an illness/treatment plan.
library;

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
    );
  }
}
