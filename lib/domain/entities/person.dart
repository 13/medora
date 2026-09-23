/// Medora - A person prescriptions are written for.
///
/// Treatments name patients by free-text tag; a person adds what a
/// pharmacy needs (the tax code) and what changes the cost (exemptions).
/// The two meet by name only, so tags keep working unchanged.
library;

class Person {
  const Person({
    required this.id,
    this.userId,
    required this.name,
    this.taxCode,
    this.exemptions = const [],
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final String name;

  /// Normalised codice fiscale (see `TaxCode.normalize`), or null.
  final String? taxCode;

  /// Exemption codes (esenzioni), e.g. "E01", "048".
  final List<String> exemptions;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// True when [tag] (a treatment's patient tag) names this person.
  bool matchesTag(String tag) =>
      tag.trim().toLowerCase() == name.trim().toLowerCase();

  /// A null argument keeps the current value (codebase convention).
  Person copyWith({
    String? id,
    String? userId,
    String? name,
    String? taxCode,
    List<String>? exemptions,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Person(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    taxCode: taxCode ?? this.taxCode,
    exemptions: exemptions ?? this.exemptions,
    notes: notes ?? this.notes,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
