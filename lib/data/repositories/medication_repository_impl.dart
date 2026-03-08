/// Medora - Medication Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/services/connectivity_service.dart';

class MedicationRepositoryImpl implements MedicationRepository {
  MedicationRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
  });

  final MedicationLocalDatasource localDatasource;
  final MedicationRemoteDatasource remoteDatasource;

  @override
  Future<Result<List<Medication>>> getMedications() async {
    try {
      final models = await localDatasource.getMedications();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load medications: $e', st);
    }
  }

  @override
  Future<Result<Medication>> getMedicationById(String id) async {
    try {
      final model = await localDatasource.getMedicationById(id);
      if (model != null) return Result.success(model.toDomain());
      return const Result.failure('Medication not found');
    } catch (e, st) {
      return Result.failure('Failed to load medication: $e', st);
    }
  }

  @override
  Future<Result<List<Medication>>> searchMedications(String query) async {
    try {
      final models = await localDatasource.searchMedications(query);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Search failed: $e', st);
    }
  }

  @override
  Future<Result<List<Medication>>> getExpiringSoon({int days = 30}) async {
    try {
      final models = await localDatasource.getExpiringSoon(days: days);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load expiring medications: $e', st);
    }
  }

  @override
  Future<Result<List<Medication>>> getLowStock() async {
    try {
      final models = await localDatasource.getLowStock();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load low stock medications: $e', st);
    }
  }

  @override
  Future<Result<Medication?>> getMedicationByBarcode(String barcode) async {
    try {
      final model = await localDatasource.getMedicationByBarcode(barcode);
      return Result.success(model?.toDomain());
    } catch (e, st) {
      return Result.failure('Barcode lookup failed: $e', st);
    }
  }

  @override
  Future<Result<Medication>> addMedication(Medication medication) async {
    try {
      final model = MedicationModel.fromDomain(medication);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncInBackground(() => remoteDatasource.addMedication(model), model.id);
      return Result.success(medication);
    } catch (e, st) {
      return Result.failure('Failed to add medication: $e', st);
    }
  }

  @override
  Future<Result<Medication>> updateMedication(Medication medication) async {
    try {
      final model = MedicationModel.fromDomain(medication);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground(() => remoteDatasource.updateMedication(model), model.id);
      return Result.success(medication);
    } catch (e, st) {
      return Result.failure('Failed to update medication: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteMedication(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncInBackground(() async {
        await remoteDatasource.deleteMedication(id);
        await localDatasource.hardDelete(id);
      }, id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete medication: $e', st);
    }
  }

  @override
  Future<Result<Medication>> updateQuantity(String id, int delta) async {
    try {
      final existing = await localDatasource.getMedicationById(id);
      if (existing == null) {
        return const Result.failure('Medication not found');
      }
      final newQty = (existing.quantity + delta).clamp(0, 999999);
      final updated = MedicationModel(
        id: existing.id,
        userId: existing.userId,
        name: existing.name,
        activeIngredients: existing.activeIngredients,
        category: existing.category,
        symptoms: existing.symptoms,
        patientTags: existing.patientTags,
        purchaseDate: existing.purchaseDate,
        expiryDate: existing.expiryDate,
        quantity: newQty,
        minimumStockLevel: existing.minimumStockLevel,
        storageLocation: existing.storageLocation,
        barcode: existing.barcode,
        imagePath: existing.imagePath,
        notes: existing.notes,
        createdAt: existing.createdAt,
        updatedAt: DateTime.now(),
      );
      await localDatasource.upsert(updated, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground(() async {
        await remoteDatasource.updateQuantity(id, delta);
      }, id);
      return Result.success(updated.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to update quantity: $e', st);
    }
  }

  @override
  Future<Result<void>> archiveMedication(String id) async {
    try {
      await localDatasource.archiveMedication(id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to archive medication: $e', st);
    }
  }

  @override
  Future<Result<void>> unarchiveMedication(String id) async {
    try {
      await localDatasource.unarchiveMedication(id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to unarchive medication: $e', st);
    }
  }

  @override
  Future<Result<List<Medication>>> getArchivedMedications() async {
    try {
      final models = await localDatasource.getArchivedMedications();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load archived medications: $e', st);
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
        debugPrint('⚠ Background sync failed for medication $id: $e');
      }
    });
  }
}
