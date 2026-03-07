/// Medora - Medication Entity
///
/// Core domain entity representing a medication in the inventory.
library;

import 'package:medora/core/constants.dart';

class Medication {
  const Medication({
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

  /// Backward-compatible getter for single active ingredient display.
  String? get activeIngredient =>
      activeIngredients.isNotEmpty ? activeIngredients.join(', ') : null;

  /// Returns true if the medication is expiring within [days].
  bool isExpiringSoon({int days = 30}) {
    if (expiryDate == null) return false;
    final now = DateTime.now();
    final diff = expiryDate!.difference(now).inDays;
    return diff >= 0 && diff <= days;
  }

  /// Returns true if the medication has expired.
  bool get isExpired {
    if (expiryDate == null) return false;
    return expiryDate!.isBefore(DateTime.now());
  }

  /// Returns true if stock is at or below minimum level.
  bool get isLowStock => quantity <= minimumStockLevel;

  /// Create a copy with modified fields.
  Medication copyWith({
    String? id,
    String? userId,
    String? name,
    String? description,
    List<String>? activeIngredients,
    String? category,
    String? manufacturer,
    String? form,
    String? atcCode,
    List<String>? symptoms,
    List<String>? patientTags,
    DateTime? purchaseDate,
    DateTime? expiryDate,
    int? quantity,
    String? quantityUnit,
    int? minimumStockLevel,
    String? storageLocation,
    String? barcode,
    String? imagePath,
    String? notes,
    bool? isArchived,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Medication(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      description: description ?? this.description,
      activeIngredients: activeIngredients ?? this.activeIngredients,
      category: category ?? this.category,
      manufacturer: manufacturer ?? this.manufacturer,
      form: form ?? this.form,
      atcCode: atcCode ?? this.atcCode,
      symptoms: symptoms ?? this.symptoms,
      patientTags: patientTags ?? this.patientTags,
      purchaseDate: purchaseDate ?? this.purchaseDate,
      expiryDate: expiryDate ?? this.expiryDate,
      quantity: quantity ?? this.quantity,
      quantityUnit: quantityUnit ?? this.quantityUnit,
      minimumStockLevel: minimumStockLevel ?? this.minimumStockLevel,
      storageLocation: storageLocation ?? this.storageLocation,
      barcode: barcode ?? this.barcode,
      imagePath: imagePath ?? this.imagePath,
      notes: notes ?? this.notes,
      isArchived: isArchived ?? this.isArchived,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
