/// Medora - Rx Dispensing Model
library;

import 'package:medora/domain/entities/rx_dispensing.dart';

class RxDispensingModel {
  const RxDispensingModel({
    required this.id,
    this.userId,
    required this.rxId,
    required this.itemId,
    required this.packs,
    required this.dispensedOn,
    this.pharmacy,
    this.unitsAdded = 0,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String rxId;
  final String itemId;
  final int packs;
  final DateTime dispensedOn;
  final String? pharmacy;
  final int unitsAdded;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  factory RxDispensingModel.fromJson(Map<String, dynamic> json) =>
      RxDispensingModel(
        id: json['id'] as String,
        userId: json['user_id'] as String?,
        rxId: json['rx_id'] as String,
        itemId: json['item_id'] as String,
        packs: (json['packs'] as num).toInt(),
        dispensedOn: DateTime.parse(json['dispensed_on'] as String),
        pharmacy: json['pharmacy'] as String?,
        unitsAdded: (json['units_added'] as num?)?.toInt() ?? 0,
        createdAt: _time(json['created_at']),
        updatedAt: _time(json['updated_at']),
        deletedAt: _time(json['deleted_at']),
      );

  factory RxDispensingModel.fromLocalMap(Map<String, dynamic> map) =>
      RxDispensingModel.fromJson(map);

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'rx_id': rxId,
    'item_id': itemId,
    'packs': packs,
    'dispensed_on': dispensedOn.toIso8601String().split('T').first,
    'pharmacy': pharmacy,
    'units_added': unitsAdded,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  RxDispensing toDomain() => RxDispensing(
    id: id,
    userId: userId,
    rxId: rxId,
    itemId: itemId,
    packs: packs,
    dispensedOn: dispensedOn,
    pharmacy: pharmacy,
    unitsAdded: unitsAdded,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory RxDispensingModel.fromDomain(RxDispensing d) => RxDispensingModel(
    id: d.id,
    userId: d.userId,
    rxId: d.rxId,
    itemId: d.itemId,
    packs: d.packs,
    dispensedOn: d.dispensedOn,
    pharmacy: d.pharmacy,
    unitsAdded: d.unitsAdded,
    createdAt: d.createdAt,
    updatedAt: d.updatedAt,
  );

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
