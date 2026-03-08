/// Medora - Treatment Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';
import 'package:medora/services/connectivity_service.dart';

class TreatmentRepositoryImpl implements TreatmentRepository {
  TreatmentRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
  });

  final TreatmentLocalDatasource localDatasource;
  final TreatmentRemoteDatasource remoteDatasource;

  @override
  Future<Result<List<Treatment>>> getTreatments() async {
    try {
      final models = await localDatasource.getTreatments();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load treatments: $e', st);
    }
  }

  @override
  Future<Result<List<Treatment>>> getActiveTreatments() async {
    try {
      final models = await localDatasource.getActiveTreatments();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load active treatments: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> getTreatmentById(String id) async {
    try {
      final model = await localDatasource.getTreatmentById(id);
      if (model != null) return Result.success(model.toDomain());
      return const Result.failure('Treatment not found');
    } catch (e, st) {
      return Result.failure('Failed to load treatment: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> addTreatment(Treatment treatment) async {
    try {
      final model = TreatmentModel.fromDomain(treatment);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncInBackground(() => remoteDatasource.addTreatment(model), model.id);
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to add treatment: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> updateTreatment(Treatment treatment) async {
    try {
      final model = TreatmentModel.fromDomain(treatment);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground(() => remoteDatasource.updateTreatment(model), model.id);
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to update treatment: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteTreatment(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncInBackground(() async {
        await remoteDatasource.deleteTreatment(id);
        await localDatasource.hardDelete(id);
      }, id);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete treatment: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> endTreatment(String id) async {
    try {
      final existing = await localDatasource.getTreatmentById(id);
      if (existing == null) return const Result.failure('Treatment not found');
      final ended = TreatmentModel(
        id: existing.id,
        userId: existing.userId,
        name: existing.name,
        patientTags: existing.patientTags,
        symptomTags: existing.symptomTags,
        startDate: existing.startDate,
        endDate: DateTime.now(),
        isActive: false,
        notes: existing.notes,
        createdAt: existing.createdAt,
      );
      await localDatasource.upsert(ended, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground(() => remoteDatasource.endTreatment(id), id);
      return Result.success(ended.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to end treatment: $e', st);
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
        debugPrint('⚠ Background sync failed for treatment $id: $e');
      }
    });
  }
}
