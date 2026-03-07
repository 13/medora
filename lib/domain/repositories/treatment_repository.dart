/// Medora - Treatment Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/treatment.dart';

abstract class TreatmentRepository {
  /// Get all treatments for the current user.
  Future<Result<List<Treatment>>> getTreatments();

  /// Get only active treatments.
  Future<Result<List<Treatment>>> getActiveTreatments();

  /// Get a single treatment by ID.
  Future<Result<Treatment>> getTreatmentById(String id);

  /// Create a new treatment.
  Future<Result<Treatment>> addTreatment(Treatment treatment);

  /// Update a treatment.
  Future<Result<Treatment>> updateTreatment(Treatment treatment);

  /// Delete a treatment.
  Future<Result<void>> deleteTreatment(String id);

  /// End a treatment (set isActive to false, set endDate).
  Future<Result<Treatment>> endTreatment(String id);
}

