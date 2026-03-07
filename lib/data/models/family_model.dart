/// Medora - Family Model
library;

import 'package:medora/domain/entities/family.dart';

class FamilyModel {
  const FamilyModel({
    required this.id,
    required this.name,
    this.inviteCode,
    this.ownerId,
    this.createdAt,
  });

  final String id;
  final String name;
  final String? inviteCode;
  final String? ownerId;
  final DateTime? createdAt;

  factory FamilyModel.fromJson(Map<String, dynamic> json) {
    return FamilyModel(
      id: json['id'] as String,
      name: json['name'] as String,
      inviteCode: json['invite_code'] as String?,
      ownerId: json['owner_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'invite_code': inviteCode,
      'owner_id': ownerId,
    };
  }

  Family toDomain() {
    return Family(
      id: id,
      name: name,
      inviteCode: inviteCode,
      ownerId: ownerId,
      createdAt: createdAt,
    );
  }

  factory FamilyModel.fromDomain(Family entity) {
    return FamilyModel(
      id: entity.id,
      name: entity.name,
      inviteCode: entity.inviteCode,
      ownerId: entity.ownerId,
      createdAt: entity.createdAt,
    );
  }
}

