/// Medora - Medication Repository Interface
///
/// Defines the contract for medication data operations.
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/medication.dart';

abstract class MedicationRepository {
  /// Get all medications for the current user.
  Future<Result<List<Medication>>> getMedications();

  /// Get a single medication by ID.
  Future<Result<Medication>> getMedicationById(String id);

  /// Search medications by name or active ingredient.
  Future<Result<List<Medication>>> searchMedications(String query);

  /// Get medications expiring within [days].
  Future<Result<List<Medication>>> getExpiringSoon({int days = 30});

  /// Get medications with low stock.
  Future<Result<List<Medication>>> getLowStock();

  /// Get medication by barcode.
  Future<Result<Medication?>> getMedicationByBarcode(String barcode);

  /// Add a new medication.
  Future<Result<Medication>> addMedication(Medication medication);

  /// Update an existing medication.
  Future<Result<Medication>> updateMedication(Medication medication);

  /// Delete a medication by ID.
  Future<Result<void>> deleteMedication(String id);

  /// Update medication quantity (increment/decrement).
  Future<Result<Medication>> updateQuantity(String id, int delta);

  /// Archive a medication (hide from active list).
  Future<Result<void>> archiveMedication(String id);

  /// Unarchive a medication.
  Future<Result<void>> unarchiveMedication(String id);

  /// Get archived medications.
  Future<Result<List<Medication>>> getArchivedMedications();
}

