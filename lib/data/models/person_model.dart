/// Medora - Person Model
library;

import 'dart:convert';

import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/model_time.dart';
import 'package:medora/domain/entities/person.dart';

class PersonModel {
  const PersonModel({
    required this.id,
    this.userId,
    required this.name,
    this.taxCode,
    this.exemptions = const [],
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String name;
  final String? taxCode;
  final List<String> exemptions;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Tombstone: non-null when the row is deleted.
  final DateTime? deletedAt;

  /// A server row.
  factory PersonModel.fromJson(Map<String, dynamic> json) => PersonModel(
    id: json['id'] as String,
    userId: json['user_id'] as String?,
    name: json['name'] as String,
    taxCode: json['tax_code'] as String?,
    exemptions: MedicationModel.parseTags(json['exemptions']),
    notes: json['notes'] as String?,
    createdAt: parseStamp(json['created_at']),
    updatedAt: parseStamp(json['updated_at']),
    deletedAt: parseStamp(json['deleted_at']),
  );

  /// A local SQLite row; same keys as the server's.
  factory PersonModel.fromLocalMap(Map<String, dynamic> map) =>
      PersonModel.fromJson(map);

  /// The wire copy: the server's columns this app writes.
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'tax_code': taxCode,
    'exemptions': jsonEncode(exemptions),
    'notes': notes,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  Person toDomain() => Person(
    id: id,
    userId: userId,
    name: name,
    taxCode: taxCode,
    exemptions: exemptions,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory PersonModel.fromDomain(Person p) => PersonModel(
    id: p.id,
    userId: p.userId,
    name: p.name,
    taxCode: p.taxCode,
    exemptions: p.exemptions,
    notes: p.notes,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  );

  PersonModel copyWith({DateTime? updatedAt, DateTime? deletedAt}) =>
      PersonModel(
        id: id,
        userId: userId,
        name: name,
        taxCode: taxCode,
        exemptions: exemptions,
        notes: notes,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt ?? this.deletedAt,
      );
}
