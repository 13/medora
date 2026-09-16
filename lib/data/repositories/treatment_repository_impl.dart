/// Medora - Treatment Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/sync_service.dart';

class TreatmentRepositoryImpl implements TreatmentRepository {
  TreatmentRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
    String? Function()? currentUserId,
  }) : _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId);

  final TreatmentLocalDatasource localDatasource;
  final TreatmentRemoteDatasource? remoteDatasource;

  /// The signed-in user every push is stamped with, as [SyncService] does.
  final String? Function() _currentUserId;

  /// The background push chain per row id. Pushes of one row run one after
  /// another, so an older copy can never land after a newer one.
  final Map<String, Future<void>> _pushChains = {};

  /// Completes once every background push started so far has finished.
  @visibleForTesting
  Future<void> get backgroundSyncIdle async {
    while (_pushChains.isNotEmpty) {
      await Future.wait(_pushChains.values.toList());
    }
  }

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
      _pushInBackground(model.id);
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
      _pushInBackground(model.id);
      return Result.success(treatment);
    } catch (e, st) {
      return Result.failure('Failed to update treatment: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteTreatment(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncInBackground(id, (remote, _) async {
        await remote.deleteTreatment(id);
        await localDatasource.hardDelete(id);
      });
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
      // The push sends the WHOLE row with an upsert; see [_pushLatest].
      _pushInBackground(id);
      return Result.success(ended.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to end treatment: $e', st);
    }
  }

  /// Fire-and-forget push of the row's current local copy; see
  /// [_pushLatest].
  void _pushInBackground(String id) => _syncInBackground(
    id,
    (remote, userId) => _pushLatest(remote, id, userId),
  );

  /// Fire-and-forget remote sync, queued behind any earlier push of the same
  /// row. No-op in local-only mode, offline, or while nobody is signed in
  /// (the sync cycle pushes the row later). A failure only logs: the row
  /// stays pending and the sync cycle retries it with backoff.
  void _syncInBackground(
    String id,
    Future<void> Function(TreatmentRemoteDatasource remote, String userId) job,
  ) {
    final remote = remoteDatasource;
    if (remote == null) return;
    if (!ConnectivityService.instance.isOnline) return;
    final userId = _currentUserId();
    if (userId == null) return;
    final previous = _pushChains[id] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) async {
          try {
            await job(remote, userId);
          } catch (e) {
            debugPrint('⚠ Background sync failed for treatment $id: $e');
          }
        })
        .whenComplete(() {
          if (identical(_pushChains[id], next)) _pushChains.remove(id);
        });
    _pushChains[id] = next;
  }

  /// Pushes the row's current local copy the way [SyncService] pushes a
  /// pending row, so the immediate push cannot lose data the sync cycle
  /// would keep:
  ///
  /// - the whole row goes up with an upsert (a plain update would match
  ///   nothing for a row the server has never seen, and marking that row
  ///   synced would strand it locally for good), stamped with the signed-in
  ///   user;
  /// - a `pending_update` is checked with [SyncService.staleAgainstRemote]
  ///   first: when the server copy is strictly newer the row is left pending
  ///   and the sync cycle pulls the winner;
  /// - the row is marked synced only if it is still the copy that was pushed
  ///   ([TreatmentLocalDatasource.markSyncedIfUnchanged]).
  ///
  /// When the row was edited while the push was in flight, the server now
  /// holds the older copy with a server-side `updated_at` that is later than
  /// the edit. That stamp is this push's own, not another device's edit, so
  /// the newer local copy is pushed again instead of losing to it.
  Future<void> _pushLatest(
    TreatmentRemoteDatasource remote,
    String id,
    String userId,
  ) async {
    DateTime? ownStamp;
    for (var attempt = 0; attempt < _maxPushAttempts; attempt++) {
      final row = await localDatasource.getUnsyncedRow(id);
      // Synced already, gone, or a delete the delete push owns.
      if (row == null || row['sync_status'] == SyncStatus.pendingDelete) {
        return;
      }
      final staleAt = await SyncService.staleAgainstRemote(
        row,
        remote.getUpdatedAt,
        force: false,
      );
      if (staleAt != null && staleAt != ownStamp) return;
      await remote.upsertTreatment(
        TreatmentModel.fromLocalMap({...row, 'user_id': userId}),
      );
      final pushedAt = row['updated_at'] as String?;
      if (pushedAt == null) return; // cannot compare; the sync cycle decides
      if (await localDatasource.markSyncedIfUnchanged(id, pushedAt)) return;
      ownStamp = await remote.getUpdatedAt(id);
    }
  }

  /// Bounds [_pushLatest] when the row keeps changing under it; whatever is
  /// still pending after that is left to the sync cycle.
  static const _maxPushAttempts = 3;
}
