/// Medora - A prescription document (Rezept / ricetta).
///
/// Not to be confused with `Prescription`, which is a dosing plan inside a
/// treatment. An [Rx] is the paper or electronic prescription a pharmacy
/// dispenses against.
library;

import 'package:medora/domain/rx/rx_rules.dart';

class RxItem {
  const RxItem({
    required this.id,
    this.medicationId,
    this.aic,
    required this.description,
    this.packs = 1,
    this.nonSubstitutable = false,
  });

  factory RxItem.fromJson(Map<String, dynamic> json) => RxItem(
    id: json['id'] as String,
    medicationId: json['medication_id'] as String?,
    aic: json['aic'] as String?,
    description: json['description'] as String? ?? '',
    packs: (json['packs'] as num?)?.toInt() ?? 1,
    nonSubstitutable: json['non_substitutable'] == true,
  );

  final String id;

  /// Soft reference to a medication in the cabinet (may dangle).
  final String? medicationId;
  final String? aic;
  final String description;
  final int packs;

  /// "Non sostituibile": the pharmacy may not hand out a generic.
  final bool nonSubstitutable;

  Map<String, Object?> toJson() => {
    'id': id,
    'medication_id': medicationId,
    'aic': aic,
    'description': description,
    'packs': packs,
    'non_substitutable': nonSubstitutable,
  };

  RxItem copyWith({
    String? medicationId,
    String? aic,
    String? description,
    int? packs,
    bool? nonSubstitutable,
  }) => RxItem(
    id: id,
    medicationId: medicationId ?? this.medicationId,
    aic: aic ?? this.aic,
    description: description ?? this.description,
    packs: packs ?? this.packs,
    nonSubstitutable: nonSubstitutable ?? this.nonSubstitutable,
  );
}

class Rx {
  const Rx({
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
  });

  final String id;
  final String? userId;

  /// Soft references: a deleted person or treatment leaves them dangling.
  final String? personId;
  final String? treatmentId;
  final RxKind kind;

  /// Normalised NRE; null for a white prescription.
  final String? nre;

  /// Date only.
  final DateTime issuedOn;

  /// Last valid day (date only); null when unknown (a referral).
  final DateTime? validUntil;
  final String? doctor;
  final String? exemptionCode;

  /// Referral priority class; null for other kinds.
  final RxPriority? priority;

  /// Repeatable white prescriptions only.
  final int? maxDispensings;
  final List<RxItem> items;

  /// Set when the user marks the prescription done by hand (a referral
  /// used, a prescription collected elsewhere).
  final DateTime? closedOn;
  final bool cancelled;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// A null argument keeps the current value (codebase convention); build a
  /// new [Rx] to clear a field.
  Rx copyWith({
    String? id,
    String? userId,
    String? personId,
    String? treatmentId,
    RxKind? kind,
    String? nre,
    DateTime? issuedOn,
    DateTime? validUntil,
    String? doctor,
    String? exemptionCode,
    RxPriority? priority,
    int? maxDispensings,
    List<RxItem>? items,
    DateTime? closedOn,
    bool? cancelled,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Rx(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    personId: personId ?? this.personId,
    treatmentId: treatmentId ?? this.treatmentId,
    kind: kind ?? this.kind,
    nre: nre ?? this.nre,
    issuedOn: issuedOn ?? this.issuedOn,
    validUntil: validUntil ?? this.validUntil,
    doctor: doctor ?? this.doctor,
    exemptionCode: exemptionCode ?? this.exemptionCode,
    priority: priority ?? this.priority,
    maxDispensings: maxDispensings ?? this.maxDispensings,
    items: items ?? this.items,
    closedOn: closedOn ?? this.closedOn,
    cancelled: cancelled ?? this.cancelled,
    notes: notes ?? this.notes,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
