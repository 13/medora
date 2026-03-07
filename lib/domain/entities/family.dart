/// Medora - Family Entity
library;

class Family {
  const Family({
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

  Family copyWith({
    String? id,
    String? name,
    String? inviteCode,
    String? ownerId,
    DateTime? createdAt,
  }) {
    return Family(
      id: id ?? this.id,
      name: name ?? this.name,
      inviteCode: inviteCode ?? this.inviteCode,
      ownerId: ownerId ?? this.ownerId,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

