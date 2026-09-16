/// Medora - Prescription Repository Implementation (Offline-First)
library;

import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';

/// Writes go to the local database only: each one stores the row as pending
/// and asks for a sync cycle, which is the one place that pushes (see
/// `TreatmentRepositoryImpl`).
class PrescriptionRepositoryImpl implements PrescriptionRepository {
  /// [requestSync] starts (or queues) a sync cycle; it is not awaited and a
  /// failure only logs. Null in local-only mode, where nothing is pushed.
  PrescriptionRepositoryImpl({
    required this.localDatasource,
    this._requestSync,
  });

  final PrescriptionLocalDatasource localDatasource;
  final RequestSync? _requestSync;

  @override
  Future<Result<List<Prescription>>> getPrescriptionsByTreatment(
    String treatmentId,
  ) async {
    try {
      final models = await localDatasource.getPrescriptionsByTreatment(
        treatmentId,
      );
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load prescriptions: $e', st);
    }
  }

  @override
  Future<Result<List<Prescription>>> getActivePrescriptions() async {
    try {
      final models = await localDatasource.getActivePrescriptions();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load active prescriptions: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> getPrescriptionById(String id) async {
    try {
      final model = await localDatasource.getPrescriptionById(id);
      if (model != null) return Result.success(model.toDomain());
      return const Result.failure('Prescription not found');
    } catch (e, st) {
      return Result.failure('Failed to load prescription: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> addPrescription(
    Prescription prescription,
  ) async {
    try {
      final now = DateTime.now();
      final updated = prescription.copyWith(createdAt: now, updatedAt: now);
      final model = PrescriptionModel.fromDomain(updated);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncSoon();
      return Result.success(updated);
    } catch (e, st) {
      return Result.failure('Failed to add prescription: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> updatePrescription(
    Prescription prescription,
  ) async {
    try {
      final previous = await localDatasource.getPrescriptionById(
        prescription.id,
      );
      final now = nextUpdatedAt(previous?.updatedAt, DateTime.now());
      final updated = prescription.copyWith(updatedAt: now);
      final model = PrescriptionModel.fromDomain(updated);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncSoon();
      return Result.success(updated);
    } catch (e, st) {
      return Result.failure('Failed to update prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deletePrescription(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deactivatePrescription(String id) async {
    try {
      await localDatasource.deactivate(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to deactivate prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> reactivatePrescription(String id) async {
    try {
      await localDatasource.reactivate(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to reactivate prescription: $e', st);
    }
  }

  /// Asks for a sync cycle without waiting for it.
  void _syncSoon() => requestSyncSoon(_requestSync, 'prescription');
}
