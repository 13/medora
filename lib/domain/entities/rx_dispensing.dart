/// Medora - One collection of packs at a pharmacy against an [Rx] item.
///
/// Its own row, never a counter on the item: two devices recording a
/// collection at once both keep theirs (a counter would lose one to the
/// whole-row merge).
library;

class RxDispensing {
  const RxDispensing({
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
  });

  final String id;
  final String? userId;
  final String rxId;

  /// `RxItem.id` within the prescription's items.
  final String itemId;
  final int packs;

  /// Date only.
  final DateTime dispensedOn;
  final String? pharmacy;

  /// Units put into the medication's stock when collected (0 = none).
  final int unitsAdded;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}
