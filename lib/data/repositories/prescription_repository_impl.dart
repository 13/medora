/// Medora - Prescription Repository Implementation (Offline-First)
library;

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
      if (ConnectivityService.instance.isOnline) {
        final remote = await remoteDatasource.getPrescriptionById(id);
        await localDatasource.upsert(remote, syncStatus: SyncStatus.synced);
        return Result.success(remote.toDomain());
      }
      return const Result.failure('Prescription not found');
    } catch (e, st) {
      return Result.failure('Failed to load prescription: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> addPrescription(Prescription prescription) async {
    try {
      final model = PrescriptionModel.fromDomain(prescription);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.addPrescription(model);
          await localDatasource.markSynced(model.id);
        } catch (_) {}
      }
      return Result.success(prescription);
    } catch (e, st) {
      return Result.failure('Failed to add prescription: $e', st);
    }
  }

  @override
  Future<Result<Prescription>> updatePrescription(
      Prescription prescription) async {
    try {
      final model = PrescriptionModel.fromDomain(prescription);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.updatePrescription(model);
          await localDatasource.markSynced(model.id);
        } catch (_) {}
      }
      return Result.success(prescription);
    } catch (e, st) {
      return Result.failure('Failed to update prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deletePrescription(String id) async {
    try {
      await localDatasource.markDeleted(id);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.deletePrescription(id);
          await localDatasource.hardDelete(id);
        } catch (_) {}
      }
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deactivatePrescription(String id) async {
    try {
      await localDatasource.deactivate(id);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.deactivatePrescription(id);
          await localDatasource.markSynced(id);
        } catch (_) {}
      }
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to deactivate prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> reactivatePrescription(String id) async {
    try {
      await localDatasource.reactivate(id);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.reactivatePrescription(id);
          await localDatasource.markSynced(id);
        } catch (_) {}
      }
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to reactivate prescription: $e', st);
    }
  }
}
