/// Medora - Family Member Entity
library;

class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.familyId,
    this.userId,
    this.displayName,
    required this.role,
    this.joinedAt,
  });

  final String id;
  final String familyId;
  final String? userId;
  final String? displayName;
  final FamilyRole role;
  final DateTime? joinedAt;
}

enum FamilyRole {
  owner,
  member;

  static FamilyRole fromString(String value) {
    return FamilyRole.values.firstWhere(
      (e) => e.name == value,
      orElse: () => FamilyRole.member,
    );
  }
}

