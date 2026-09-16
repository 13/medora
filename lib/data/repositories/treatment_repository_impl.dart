/// Medora - Treatment Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
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
  final TreatmentRemoteDatasource? remoteDatasource;

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
      final model = TreatmentModel.fromDomain(
        treatment.copyWith(
          updatedAt: DateTime.now(),
          createdAt: treatment.createdAt ?? DateTime.now(),
        ),
      );
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncInBackground((r) => r.addTreatment(model), model.id);
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to add treatment: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> updateTreatment(Treatment treatment) async {
    try {
      final previous = await localDatasource.getTreatmentById(treatment.id);
      final model = TreatmentModel.fromDomain(
        treatment.copyWith(
          updatedAt: nextUpdatedAt(previous?.updatedAt, DateTime.now()),
        ),
      );
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncInBackground((r) => r.updateTreatment(model), model.id);
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to update treatment: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteTreatment(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncInBackground((r) async {
        await r.deleteTreatment(id);
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
      final now = DateTime.now();
      // Copy, never rebuild: a field-by-field rebuild drops every column
      // the author did not list (this is how the sick-leave columns were
      // silently lost on every "End").
      final ended = existing.copyWith(
        endDate: now,
        isActive: false,
        updatedAt: nextUpdatedAt(existing.updatedAt, now),
      );
      await localDatasource.upsert(ended, syncStatus: SyncStatus.pendingUpdate);
      // Push the WHOLE row. _syncInBackground marks the row synced on
      // success, so a partial remote update would strand every column it
      // omitted.
      _syncInBackground((r) => r.upsertTreatment(ended), id);
      return Result.success(ended.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to end treatment: $e', st);
    }
  }

  /// Fire-and-forget remote sync. No-op in local-only mode.
  void _syncInBackground(
    Future<dynamic> Function(TreatmentRemoteDatasource remote) remoteFn,
    String id,
  ) {
    final remote = remoteDatasource;
    if (remote == null) return;
    if (!ConnectivityService.instance.isOnline) return;
    Future(() async {
      try {
        await remoteFn(remote);
        await localDatasource.markSynced(id);
      } catch (e) {
        debugPrint('⚠ Background sync failed for treatment $id: $e');
      }
    });
  }
}
