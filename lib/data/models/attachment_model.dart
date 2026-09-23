/// Medora - Attachment Model
library;

import 'package:medora/data/models/model_time.dart';
import 'package:medora/domain/entities/attachment.dart';

class AttachmentModel {
  const AttachmentModel({
    required this.id,
    this.userId,
    required this.ownerKind,
    required this.ownerId,
    required this.kind,
    required this.mime,
    required this.sizeBytes,
    required this.sha256,
    this.originalName,
    this.remotePath,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final AttachmentOwnerKind ownerKind;
  final String ownerId;
  final AttachmentKind kind;
  final String mime;
  final int sizeBytes;
  final String sha256;
  final String? originalName;
  final String? remotePath;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Tombstone: non-null when the row is deleted.
  final DateTime? deletedAt;

  /// A server row.
  factory AttachmentModel.fromJson(Map<String, dynamic> json) =>
      AttachmentModel(
        id: json['id'] as String,
        userId: json['user_id'] as String?,
        ownerKind: AttachmentOwnerKind.fromWire(json['owner_kind'] as String?),
        ownerId: json['owner_id'] as String,
        kind: AttachmentKind.fromWire(json['kind'] as String?),
        mime: json['mime'] as String,
        sizeBytes: (json['size_bytes'] as num).toInt(),
        sha256: json['sha256'] as String,
        originalName: json['original_name'] as String?,
        remotePath: json['remote_path'] as String?,
        createdAt: parseStamp(json['created_at']),
        updatedAt: parseStamp(json['updated_at']),
        deletedAt: parseStamp(json['deleted_at']),
      );

  /// A local SQLite row; same keys as the server's.
  factory AttachmentModel.fromLocalMap(Map<String, dynamic> map) =>
      AttachmentModel.fromJson(map);

  /// The wire copy: the server's columns this app writes.
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'owner_kind': ownerKind.wire,
    'owner_id': ownerId,
    'kind': kind.wire,
    'mime': mime,
    'size_bytes': sizeBytes,
    'sha256': sha256,
    'original_name': originalName,
    'remote_path': remotePath,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  Attachment toDomain() => Attachment(
    id: id,
    userId: userId,
    ownerKind: ownerKind,
    ownerId: ownerId,
    kind: kind,
    mime: mime,
    sizeBytes: sizeBytes,
    sha256: sha256,
    originalName: originalName,
    remotePath: remotePath,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory AttachmentModel.fromDomain(Attachment a) => AttachmentModel(
    id: a.id,
    userId: a.userId,
    ownerKind: a.ownerKind,
    ownerId: a.ownerId,
    kind: a.kind,
    mime: a.mime,
    sizeBytes: a.sizeBytes,
    sha256: a.sha256,
    originalName: a.originalName,
    remotePath: a.remotePath,
    createdAt: a.createdAt,
    updatedAt: a.updatedAt,
  );

  AttachmentModel copyWith({
    String? remotePath,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) => AttachmentModel(
    id: id,
    userId: userId,
    ownerKind: ownerKind,
    ownerId: ownerId,
    kind: kind,
    mime: mime,
    sizeBytes: sizeBytes,
    sha256: sha256,
    originalName: originalName,
    remotePath: remotePath ?? this.remotePath,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
  );
}
