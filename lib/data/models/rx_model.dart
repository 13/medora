/// Medora - Rx Model (prescription document).
library;

import 'dart:convert';

import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';

class RxModel {
  const RxModel({
    required this.id,
    this.userId,
    this.personId,
    this.treatmentId,
    required this.kind,
    this.nre,
    required this.issuedOn,
    this.validUntil,
    this.doctor,
    this.exemptionCode,
    this.priority,
    this.maxDispensings,
    this.items = const [],
    this.closedOn,
    this.cancelled = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String? personId;
  final String? treatmentId;
  final RxKind kind;
  final String? nre;
  final DateTime issuedOn;
  final DateTime? validUntil;
  final String? doctor;
  final String? exemptionCode;
  final RxPriority? priority;
  final int? maxDispensings;
  final List<RxItem> items;
  final DateTime? closedOn;
  final bool cancelled;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// A server row: `items` arrives as a JSON array (jsonb), `cancelled` as
  /// a bool.
  factory RxModel.fromJson(Map<String, dynamic> json) => RxModel(
    id: json['id'] as String,
    userId: json['user_id'] as String?,
    personId: json['person_id'] as String?,
    treatmentId: json['treatment_id'] as String?,
    kind: RxKind.fromWire(json['kind'] as String?),
    nre: json['nre'] as String?,
    issuedOn: DateTime.parse(json['issued_on'] as String),
    validUntil: _date(json['valid_until']),
    doctor: json['doctor'] as String?,
    exemptionCode: json['exemption_code'] as String?,
    priority: RxPriority.fromWire(json['priority'] as String?),
    maxDispensings: (json['max_dispensings'] as num?)?.toInt(),
    items: parseItems(json['items']),
    closedOn: _date(json['closed_on']),
    cancelled: json['cancelled'] == true || json['cancelled'] == 1,
    notes: json['notes'] as String?,
    createdAt: _time(json['created_at']),
    updatedAt: _time(json['updated_at']),
    deletedAt: _time(json['deleted_at']),
  );

  /// A local row: `items` is JSON text, `cancelled` 0/1.
  factory RxModel.fromLocalMap(Map<String, dynamic> map) =>
      RxModel.fromJson(map);

  /// Items from a JSON array or its text.
  static List<RxItem> parseItems(Object? raw) {
    final decoded = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map) RxItem.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// The wire copy. `items` is a list here (jsonb on the server); the merge
  /// compares it as a whole.
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'person_id': personId,
    'treatment_id': treatmentId,
    'kind': kind.wire,
    'nre': nre,
    'issued_on': _dateText(issuedOn),
    'valid_until': validUntil == null ? null : _dateText(validUntil!),
    'doctor': doctor,
    'exemption_code': exemptionCode,
    'priority': priority?.wire,
    'max_dispensings': maxDispensings,
    'items': [for (final i in items) i.toJson()],
    'closed_on': closedOn == null ? null : _dateText(closedOn!),
    'cancelled': cancelled,
    'notes': notes,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  Rx toDomain() => Rx(
    id: id,
    userId: userId,
    personId: personId,
    treatmentId: treatmentId,
    kind: kind,
    nre: nre,
    issuedOn: issuedOn,
    validUntil: validUntil,
    doctor: doctor,
    exemptionCode: exemptionCode,
    priority: priority,
    maxDispensings: maxDispensings,
    items: items,
    closedOn: closedOn,
    cancelled: cancelled,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory RxModel.fromDomain(Rx r) => RxModel(
    id: r.id,
    userId: r.userId,
    personId: r.personId,
    treatmentId: r.treatmentId,
    kind: r.kind,
    nre: r.nre,
    issuedOn: r.issuedOn,
    validUntil: r.validUntil,
    doctor: r.doctor,
    exemptionCode: r.exemptionCode,
    priority: r.priority,
    maxDispensings: r.maxDispensings,
    items: r.items,
    closedOn: r.closedOn,
    cancelled: r.cancelled,
    notes: r.notes,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  RxModel copyWith({
    String? doctor,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) => RxModel(
    id: id,
    userId: userId,
    personId: personId,
    treatmentId: treatmentId,
    kind: kind,
    nre: nre,
    issuedOn: issuedOn,
    validUntil: validUntil,
    doctor: doctor ?? this.doctor,
    exemptionCode: exemptionCode,
    priority: priority,
    maxDispensings: maxDispensings,
    items: items,
    closedOn: closedOn,
    cancelled: cancelled,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
  );

  static String _dateText(DateTime d) => d.toIso8601String().split('T').first;
  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
