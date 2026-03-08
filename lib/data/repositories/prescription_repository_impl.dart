/// Medora - Prescription Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';
import 'package:medora/services/connectivity_service.dart';

class PrescriptionRepositoryImpl implements PrescriptionRepository {
  PrescriptionRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
  });

  final PrescriptionLocalDatasource localDatasource;
  final PrescriptionRemoteDatasource remoteDatasource;

  @override
  Future<Result<List<Prescription>>> getPrescriptionsByTreatment(
      String treatmentId) async {
    try {
      final models =
          await localDatasource.getPrescriptionsByTreatment(treatmentId);
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
  Future<Result<Prescription>> addPrescription(Prescription prescription) async {
    try {
      final now = DateTime.now();
      final updated = prescription.copyWith(createdAt: now, updatedAt: now);
      final model = PrescriptionModel.fromDomain(updated);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncInBackground(() => remoteDatasource.addPrescription(model), model.id);
      return Result.success(updated);
    } catch (e, st) {
      return Result.failure('Failed to add prescription: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> updatePrescription(
      Prescription prescription) async {
    try {
      final now = DateTime.now();
      final updated = prescription.copyWith(updatedAt: now);
      final model = PrescriptionModel.fromDomain(updated);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground(() => remoteDatasource.updatePrescription(model), model.id);
      return Result.success(updated);
    } catch (e, st) {
      return Result.failure('Failed to update prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deletePrescription(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncInBackground(() async {
        await remoteDatasource.deletePrescription(id);
        await localDatasource.hardDelete(id);
      }, id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deactivatePrescription(String id) async {
    try {
      await localDatasource.deactivate(id);
      _syncInBackground(() => remoteDatasource.deactivatePrescription(id), id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to deactivate prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> reactivatePrescription(String id) async {
    try {
      await localDatasource.reactivate(id);
      _syncInBackground(() => remoteDatasource.reactivatePrescription(id), id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to reactivate prescription: $e', st);
    }
  }

  /// Fire-and-forget remote sync.
  void _syncInBackground(Future<dynamic> Function() remoteFn, String id) {
    if (!ConnectivityService.instance.isOnline) return;
    Future(() async {
      try {
        await remoteFn();
        await localDatasource.markSynced(id);
      } catch (e) {
        debugPrint('⚠ Background sync failed for prescription $id: $e');
      }
    });
  }
}
