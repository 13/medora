import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';

/// Forwards every [DoseLogRepository] method to [inner] except
/// [markDoseTaken], which always fails — used to exercise the Now card's
/// error handling when `DoseActions.take` reports failure.
class FailingTakeRepo implements DoseLogRepository {
  FailingTakeRepo(this.inner);
  final DoseLogRepository inner;

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByPrescription(
    String prescriptionId,
  ) => inner.getDoseLogsByPrescription(prescriptionId);

  @override
  Future<Result<DoseLog>> getDoseLogById(String id) => inner.getDoseLogById(id);

  @override
  Future<Result<List<DoseLog>>> getTodaysDoseLogs() =>
      inner.getTodaysDoseLogs();

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  ) => inner.getDoseLogsByDateRange(start, end);

  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(
    DateTime start,
    DateTime end,
  ) => inner.getPendingDoseLogsBetween(start, end);

  @override
  Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff) =>
      inner.markOverduePendingAsMissed(cutoff);

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) =>
      inner.addDoseLog(doseLog);

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) async =>
      const Result.failure('db down');

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) =>
      inner.markDoseSkipped(id);

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) => inner.markDoseMissed(id);

  @override
  Future<Result<DoseLog>> markDosePending(String id) =>
      inner.markDosePending(id);

  @override
  Future<Result<void>> deleteDoseLog(String id) => inner.deleteDoseLog(id);

  @override
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
    String prescriptionId,
  ) => inner.generateDoseLogsForPrescription(prescriptionId);

  @override
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
    String prescriptionId,
  ) => inner.regenerateDoseLogsForPrescription(prescriptionId);
}
