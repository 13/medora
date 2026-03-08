/// Medora - Medication Model
///
/// Data layer model for serialization to/from Supabase JSON and SQLite.
library;

import 'dart:convert';

import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/medication.dart';

class MedicationModel {
  const MedicationModel({
    required this.id,
    this.userId,
    required this.name,
    this.description,
    this.activeIngredients = const [],
    this.category,
    this.manufacturer,
    this.form,
    this.atcCode,
    this.symptoms = const [],
    this.patientTags = const [],
    this.purchaseDate,
    this.expiryDate,
    required this.quantity,
    this.quantityUnit,
    this.minimumStockLevel = AppConstants.defaultMinimumStock,
    this.storageLocation,
    this.barcode,
    this.imagePath,
    this.notes,
    this.isArchived = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final String name;
  final String? description;
  final List<String> activeIngredients;
  final String? category;
  final String? manufacturer;
  final String? form;
  final String? atcCode;
  final List<String> symptoms;
  final List<String> patientTags;
  final DateTime? purchaseDate;
  final DateTime? expiryDate;
  final int quantity;
  final String? quantityUnit;
  final int minimumStockLevel;
  final String? storageLocation;
  final String? barcode;
  final String? imagePath;
  final String? notes;
  final bool isArchived;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Helper: parse a JSON array or comma-separated string into a list of strings.
  static List<String> parseTags(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.cast<String>();
    if (raw is String && raw.isNotEmpty) {
      if (raw.startsWith('[') && raw.endsWith(']')) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) return decoded.cast<String>();
        } catch (_) {}
      }
      // Fallback: comma-separated
      return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  /// Create from Supabase JSON row.
  factory MedicationModel.fromJson(Map<String, dynamic> json) {
    return MedicationModel(
      id: json['id'] as String,
      userId: json['user_id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      activeIngredients: parseTags(json['active_ingredients'] ?? json['active_ingredient']),
      category: json['category'] as String?,
      manufacturer: json['manufacturer'] as String?,
      form: json['form'] as String?,
      atcCode: json['atc_code'] as String?,
      symptoms: parseTags(json['symptoms']),
      patientTags: parseTags(json['patient_tags']),
      purchaseDate: json['purchase_date'] != null
          ? DateTime.parse(json['purchase_date'] as String)
          : null,
      expiryDate: json['expiry_date'] != null
          ? DateTime.parse(json['expiry_date'] as String)
          : null,
      quantity: json['quantity'] as int? ?? 0,
      quantityUnit: json['quantity_unit'] as String?,
      minimumStockLevel: json['minimum_stock_level'] as int? ?? 0,
      storageLocation: json['storage_location'] as String?,
      barcode: json['barcode'] as String?,
      imagePath: json['image_path'] as String?,
      notes: json['notes'] as String?,
      isArchived: json['is_archived'] == true || json['is_archived'] == 1,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
    );
  }

  /// Create from local SQLite row.
  factory MedicationModel.fromLocalMap(Map<String, dynamic> map) {
    return MedicationModel(
      id: map['id'] as String,
      userId: map['user_id'] as String?,
      name: map['name'] as String,
      description: map['description'] as String?,
      activeIngredients: parseTags(map['active_ingredients'] ?? map['active_ingredient']),
      category: map['category'] as String?,
      manufacturer: map['manufacturer'] as String?,
      form: map['form'] as String?,
      atcCode: map['atc_code'] as String?,
      symptoms: parseTags(map['symptoms']),
      patientTags: parseTags(map['patient_tags']),
      purchaseDate: map['purchase_date'] != null
          ? DateTime.tryParse(map['purchase_date'] as String)
          : null,
      expiryDate: map['expiry_date'] != null
          ? DateTime.tryParse(map['expiry_date'] as String)
          : null,
      quantity: map['quantity'] as int? ?? 0,
      quantityUnit: map['quantity_unit'] as String?,
      minimumStockLevel: map['minimum_stock_level'] as int? ?? 0,
      storageLocation: map['storage_location'] as String?,
      barcode: map['barcode'] as String?,
      imagePath: map['image_path'] as String?,
      notes: map['notes'] as String?,
      isArchived: (map['is_archived'] as int? ?? 0) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }

  /// Convert to Supabase JSON for insert/update.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'description': description,
      'active_ingredients': jsonEncode(activeIngredients),
      'category': category,
      'manufacturer': manufacturer,
      'form': form,
      'atc_code': atcCode,
      'symptoms': jsonEncode(symptoms),
      'patient_tags': jsonEncode(patientTags),
      'purchase_date': purchaseDate?.toIso8601String().split('T').first,
      'expiry_date': expiryDate?.toIso8601String().split('T').first,
      'quantity': quantity,
      'quantity_unit': quantityUnit,
      'minimum_stock_level': minimumStockLevel,
      'storage_location': storageLocation,
      'barcode': barcode,
      'image_path': imagePath,
      'notes': notes,
      'is_archived': isArchived,
    };
  }

  /// Convert to domain entity.
  Medication toDomain() {
    return Medication(
      id: id,
      userId: userId,
      name: name,
      description: description,
      activeIngredients: activeIngredients,
      category: category,
      manufacturer: manufacturer,
      form: form,
      atcCode: atcCode,
      symptoms: symptoms,
      patientTags: patientTags,
      purchaseDate: purchaseDate,
      expiryDate: expiryDate,
      quantity: quantity,
      quantityUnit: quantityUnit,
      minimumStockLevel: minimumStockLevel,
      storageLocation: storageLocation,
      barcode: barcode,
      imagePath: imagePath,
      notes: notes,
      isArchived: isArchived,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Create from domain entity.
  factory MedicationModel.fromDomain(Medication entity) {
    return MedicationModel(
      id: entity.id,
      userId: entity.userId,
      name: entity.name,
      description: entity.description,
      activeIngredients: entity.activeIngredients,
      category: entity.category,
      manufacturer: entity.manufacturer,
      form: entity.form,
      atcCode: entity.atcCode,
      symptoms: entity.symptoms,
      patientTags: entity.patientTags,
      purchaseDate: entity.purchaseDate,
      expiryDate: entity.expiryDate,
      quantity: entity.quantity,
      quantityUnit: entity.quantityUnit,
      minimumStockLevel: entity.minimumStockLevel,
      storageLocation: entity.storageLocation,
      barcode: entity.barcode,
      imagePath: entity.imagePath,
      notes: entity.notes,
      isArchived: entity.isArchived,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
    );
  }
}
