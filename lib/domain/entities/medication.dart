/// Medora - Medication Entity
///
/// Core domain entity representing a medication in the inventory.
library;

import 'package:medora/core/clock.dart';
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
    this.ean,
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

  /// The EAN barcode printed on the pack, when a scan saw one next to the
  /// label code in [barcode]. Matching a scanned code checks both.
  final String? ean;

  final String? imagePath;
  final String? notes;
  final bool isArchived;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Backward-compatible getter for single active ingredient display.
  String? get activeIngredient =>
      activeIngredients.isNotEmpty ? activeIngredients.join(', ') : null;

  /// Whole days from [now] until the expiry date, or `null` when no expiry
  /// date is set. Negative once the medication has expired.
  int? daysUntilExpiry(DateTime now) {
    final expiry = expiryDate;
    if (expiry == null) return null;
    return calendarDaysBetween(now, expiry);
  }

  /// Returns true if the medication is expiring within [days] of [now]
  /// (defaults to the system clock when no clock is injected).
  bool isExpiringSoon({int days = 30, DateTime? now}) {
    final remaining = daysUntilExpiry(now ?? systemNow());
    if (remaining == null) return false;
    return remaining >= 0 && remaining <= days;
  }

  /// Returns true if the medication had expired at [now].
  ///
  /// Calendar days, not instants: an expiry date is a date, so a medication
  /// stamped "expires today" is good for the whole of today and expires
  /// tomorrow. Comparing instants made it expire at midnight, which
  /// disagreed with the badge and the countdown - both of which round to
  /// whole days through [daysUntilExpiry].
  bool expiredAt(DateTime now) {
    final remaining = daysUntilExpiry(now);
    return remaining != null && remaining < 0;
  }

  /// Returns true if the medication has expired, per the system clock.
  /// Prefer [expiredAt] wherever a clock is available.
  bool get isExpired => expiredAt(systemNow());

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
    String? ean,
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
      ean: ean ?? this.ean,
      imagePath: imagePath ?? this.imagePath,
      notes: notes ?? this.notes,
      isArchived: isArchived ?? this.isArchived,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
