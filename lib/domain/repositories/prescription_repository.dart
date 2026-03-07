/// Medora - Prescription Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/prescription.dart';

abstract class PrescriptionRepository {
  /// Get all prescriptions for a treatment.
  Future<Result<List<Prescription>>> getPrescriptionsByTreatment(
    String treatmentId,
  );

  /// Get all active prescriptions.
  Future<Result<List<Prescription>>> getActivePrescriptions();

  /// Get a single prescription by ID.
  Future<Result<Prescription>> getPrescriptionById(String id);

  /// Create a new prescription.
  Future<Result<Prescription>> addPrescription(Prescription prescription);

  /// Update a prescription.
  Future<Result<Prescription>> updatePrescription(Prescription prescription);

  /// Delete a prescription.
  Future<Result<void>> deletePrescription(String id);

  /// Deactivate a prescription.
  Future<Result<void>> deactivatePrescription(String id);

  /// Reactivate a deactivated prescription.
  Future<Result<void>> reactivatePrescription(String id);
}

