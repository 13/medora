/// Medora - Family Member Model
library;

import 'package:medora/domain/entities/family_member.dart';

class FamilyMemberModel {
  const FamilyMemberModel({
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
  final String role;
  final DateTime? joinedAt;

  factory FamilyMemberModel.fromJson(Map<String, dynamic> json) {
    return FamilyMemberModel(
      id: json['id'] as String,
      familyId: json['family_id'] as String,
      userId: json['user_id'] as String?,
      displayName: json['display_name'] as String?,
      role: json['role'] as String? ?? 'member',
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'family_id': familyId,
      'user_id': userId,
      'display_name': displayName,
      'role': role,
    };
  }

  FamilyMember toDomain() {
    return FamilyMember(
      id: id,
      familyId: familyId,
      userId: userId,
      displayName: displayName,
      role: FamilyRole.fromString(role),
      joinedAt: joinedAt,
    );
  }
}

