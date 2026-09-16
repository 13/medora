/// Medora - Treatment Repository Implementation (Offline-First)
library;

import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';

/// Writes go to the local database only. Every add, update, End and delete
/// stores the row as pending and then asks for a sync cycle, which is the
/// one place that pushes: it applies last-write-wins, stamps the signed-in
/// user, and marks a row synced only while it is still the copy it pushed.
/// The cycle queues behind one that is already running, so an edit made
/// mid-cycle goes out on the re-run.
class TreatmentRepositoryImpl implements TreatmentRepository {
  /// [requestSync] starts (or queues) a sync cycle. It is not awaited, and a
  /// failure only logs: the row stays pending for the next cycle. Null in
  /// local-only mode, where nothing is pushed.
  ///
  /// [now] is the clock for the dates and stamps a write sets.
  TreatmentRepositoryImpl({
    required this.localDatasource,
    this._requestSync,
    this._now = systemNow,
  });

  final TreatmentLocalDatasource localDatasource;
  final RequestSync? _requestSync;
  final Now _now;

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
      final now = _now();
      final model = TreatmentModel.fromDomain(
        treatment.copyWith(
          updatedAt: now,
          createdAt: treatment.createdAt ?? now,
        ),
      );
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncSoon();
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
          updatedAt: nextUpdatedAt(previous?.updatedAt, _now()),
        ),
      );
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingUpdate);
      _syncSoon();
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to update treatment: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteTreatment(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete treatment: $e', st);
    }
  }

  @override
  Future<Result<Treatment>> endTreatment(
    String id, {
    bool endSickLeave = false,
  }) async {
    try {
      final existing = await localDatasource.getTreatmentById(id);
      if (existing == null) return const Result.failure('Treatment not found');
      // Ending a row deleted on this device would overwrite its tombstone
      // and pending delete, silently undoing the delete.
      if (existing.deletedAt != null) {
        return const Result.failure('Treatment was deleted');
      }
      final now = _now();
      // Copy, never rebuild: a field-by-field rebuild drops every column
      // the author did not list (this is how the sick-leave columns were
      // silently lost on every "End").
      final ended = existing.copyWith(
        endDate: now,
        isActive: false,
        // Null keeps the stored value: a closed leave is never moved.
        sickLeaveTo: endSickLeave
            ? existing.toDomain().sickLeaveEndAt(now)
            : null,
        updatedAt: nextUpdatedAt(existing.updatedAt, now),
      );
      // The sync cycle pushes the WHOLE row with an upsert.
      await localDatasource.upsert(ended, syncStatus: SyncStatus.pendingUpdate);
      _syncSoon();
      return Result.success(ended.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to end treatment: $e', st);
    }
  }

  /// Asks for a sync cycle without waiting for it.
  void _syncSoon() => requestSyncSoon(_requestSync, 'treatment');
}
