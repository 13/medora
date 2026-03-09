/// Medora - Dose Log Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/dose_log.dart';

abstract class DoseLogRepository {
  /// Get dose logs for a prescription.
  Future<Result<List<DoseLog>>> getDoseLogsByPrescription(
    String prescriptionId,
  );

  /// Get all dose logs for today.
  Future<Result<List<DoseLog>>> getTodaysDoseLogs();

  /// Get dose logs for a date range.
  Future<Result<List<DoseLog>>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  );

  /// Create a new dose log entry.
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog);

  /// Mark a dose as taken.
  Future<Result<DoseLog>> markDoseTaken(String id);

  /// Mark a dose as skipped.
  Future<Result<DoseLog>> markDoseSkipped(String id);

  /// Mark a dose as missed.
  Future<Result<DoseLog>> markDoseMissed(String id);

  /// Mark a dose as pending (undo take/skip/miss).
  Future<Result<DoseLog>> markDosePending(String id);

  /// Generate dose log entries for a prescription.
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
    String prescriptionId,
  );

  /// Regenerate dose logs for an updated prescription.
  /// Deletes old pending doses and creates new ones.
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
    String prescriptionId,
  );
}
