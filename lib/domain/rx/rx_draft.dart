/// Medora - What a scan read off a prescription, before the user confirms it.
///
/// Every field is a suggestion: the form shows it and the user checks it.
/// [RxDraft.fromBarcode] tells the trusted (barcode) values from the ones
/// only recognised in the text.
library;

import 'package:medora/domain/rx/rx_rules.dart';

class RxDraftItem {
  const RxDraftItem({
    this.aic,
    required this.description,
    this.packs = 1,
    this.posology,
  });

  final String? aic;
  final String description;
  final int packs;
  final String? posology;
}

class RxDraft {
  const RxDraft({
    this.kind,
    this.nre,
    this.pin,
    this.taxCode,
    this.patientName,
    this.doctor,
    this.doctorTaxCode,
    this.issuedOn,
    this.validUntil,
    this.validDays,
    this.maxDispensings,
    this.exemptionCode,
    this.priority,
    this.items = const [],
    this.fromBarcode = const {},
  });

  final RxKind? kind;
  final String? nre;
  final String? pin;

  /// The patient's tax code.
  final String? taxCode;
  final String? patientName;
  final String? doctor;
  final String? doctorTaxCode;

  /// Dates only.
  final DateTime? issuedOn;
  final DateTime? validUntil;

  /// Set when [validUntil] was computed from a printed "valid for n days"
  /// rather than printed as a date: the validity then follows the issue
  /// date when the user corrects it.
  final int? validDays;
  final int? maxDispensings;
  final String? exemptionCode;
  final RxPriority? priority;
  final List<RxDraftItem> items;

  /// Field names read from a barcode (trusted) rather than text (suggested):
  /// 'nre', 'pin', 'taxCode', 'doctorTaxCode'.
  final Set<String> fromBarcode;

  /// Nothing recognised at all.
  bool get isEmpty =>
      kind == null &&
      nre == null &&
      pin == null &&
      taxCode == null &&
      patientName == null &&
      doctor == null &&
      doctorTaxCode == null &&
      issuedOn == null &&
      validUntil == null &&
      maxDispensings == null &&
      exemptionCode == null &&
      priority == null &&
      items.isEmpty;
}
