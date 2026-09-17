/// Medora - Dose Log Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';

/// Writes go to the local database only: each one stores the rows as
/// pending and asks for a sync cycle, which is the one place that pushes
/// (see `TreatmentRepositoryImpl`).
class DoseLogRepositoryImpl implements DoseLogRepository {
  /// [requestSync] starts (or queues) a sync cycle; it is not awaited and a
  /// failure only logs. Null in local-only mode, where nothing is pushed.
  ///
  /// [now] is the clock for the times a write sets.
  DoseLogRepositoryImpl({
    required this.localDatasource,
    required this.prescriptionLocal,
    this._requestSync,
    this._now = systemNow,
  });

  final DoseLogLocalDatasource localDatasource;
  final PrescriptionLocalDatasource prescriptionLocal;
  final RequestSync? _requestSync;
  final Now _now;

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByPrescription(
    String prescriptionId,
  ) async {
    try {
      final models = await localDatasource.getDoseLogsByPrescription(
        prescriptionId,
      );
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load dose logs: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByTreatment(
    String treatmentId,
  ) async {
    try {
      final models = await localDatasource.getDoseLogsByTreatment(treatmentId);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load dose logs: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> getTodaysDoseLogs() async {
    try {
      final models = await localDatasource.getTodaysDoseLogs();
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load today\'s doses: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final models = await localDatasource.getDoseLogsByDateRange(start, end);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load dose logs: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> getPendingDoseLogsBetween(
    DateTime start,
    DateTime end,
  ) async {
    try {
      final models = await localDatasource.getPendingBetween(start, end);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load pending doses: $e', st);
    }
  }

  @override
  Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff) async {
    try {
      final (:changed, :unpushed) = await localDatasource
          .markOverduePendingAsMissed(cutoff);
      // A dose the server already has stays `synced`: the change is local
      // only (see the datasource), so there is nothing to push.
      if (unpushed > 0) _syncSoon();
      return Result.success(changed);
    } catch (e, st) {
      return Result.failure('Failed to mark overdue doses: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) async {
    try {
      final model = DoseLogModel.fromDomain(doseLog);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncSoon();
      return Result.success(doseLog);
    } catch (e, st) {
      return Result.failure('Failed to add dose log: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> getDoseLogById(String id) async {
    try {
      final model = await localDatasource.getDoseLogById(id);
      if (model == null) return const Result.failure('Dose log not found');
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to load dose log: $e', st);
    }
  }

  /// Shared status mutation: update locally, ask for a sync, return the
  /// stored row.
  Future<Result<DoseLog>> _changeStatus(
    String id,
    String status, {
    DateTime? takenTime,
    bool clearTakenTime = false,
  }) async {
    try {
      final existing = await localDatasource.getDoseLogById(id);
      if (existing == null) return const Result.failure('Dose log not found');

      await localDatasource.updateStatus(
        id,
        status,
        takenTime: takenTime,
        clearTakenTime: clearTakenTime,
        syncStatus: SyncStatus.pendingUpdate,
      );
      _syncSoon();
      final updated = await localDatasource.getDoseLogById(id);
      return Result.success(updated!.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to mark dose as $status: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) =>
      _changeStatus(id, 'taken', takenTime: _now());

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) =>
      _changeStatus(id, 'skipped');

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) =>
      _changeStatus(id, 'missed');

  @override
  Future<Result<DoseLog>> markDosePending(String id) =>
      _changeStatus(id, 'pending', clearTakenTime: true);

  @override
  Future<Result<void>> deleteDoseLog(String id) async {
    try {
      final existing = await localDatasource.getDoseLogById(id);
      if (existing == null) return const Result.failure('Dose log not found');
      await localDatasource.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete dose log: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
    String prescriptionId,
  ) async {
    try {
      final prescription = await prescriptionLocal.getPrescriptionById(
        prescriptionId,
      );
      if (prescription == null) {
        debugPrint(
          '⚠ generateDoseLogs: Prescription $prescriptionId not found in local DB',
        );
        return const Result.failure('Prescription not found');
      }

      // An ended treatment's prescriptions keep their own state, but get no
      // new doses (and so no reminders) until the treatment runs again.
      if (await prescriptionLocal.isInEndedTreatment(prescriptionId)) {
        debugPrint(
          'generateDoseLogs: prescription $prescriptionId belongs to an '
          'ended treatment; nothing to generate',
        );
        return const Result.success([]);
      }

      final entity = prescription.toDomain();
      final scheduledTimes = entity.scheduledDoseTimes;

      if (scheduledTimes.isEmpty) {
        debugPrint(
          '⚠ generateDoseLogs: No scheduled times generated for prescription $prescriptionId',
        );
        return const Result.success([]);
      }

      // A slot is there when a dose has its time or its id: a row stored
      // under the id at another time (written by an older build) is kept,
      // never replaced.
      final existingModels = await localDatasource.getDoseLogsByPrescription(
        prescriptionId,
      );
      final existingTimes = {
        for (final m in existingModels) doseSlotKey(m.scheduledTime),
      };
      final existingIds = {for (final m in existingModels) m.id};

      final newDoseLogs = <DoseLogModel>[];
      final now = _now();
      // A generated dose carries the weakest stamp there is, and the sync
      // cycle only inserts it where the server does not have it yet: a copy
      // of the same dose that someone took, skipped or marked on another
      // device always wins over this one.
      for (final time in scheduledTimes) {
        if (existingTimes.contains(doseSlotKey(time))) continue;
        final id = scheduledDoseId(prescriptionId, time);
        if (existingIds.contains(id)) continue;
        newDoseLogs.add(
          DoseLogModel(
            id: id,
            prescriptionId: prescriptionId,
            scheduledTime: time,
            createdAt: now,
            updatedAt: generatedUpdatedAt,
          ),
        );
      }

      if (newDoseLogs.isEmpty) {
        debugPrint(
          '✅ generateDoseLogs: All ${scheduledTimes.length} dose logs already exist for prescription $prescriptionId',
        );
        return Result.success(existingModels.map((m) => m.toDomain()).toList());
      }

      debugPrint(
        '✅ generateDoseLogs: Creating ${newDoseLogs.length} new dose logs '
        '(${existingModels.length} already exist) for prescription $prescriptionId',
      );

      await localDatasource.insertBatchIfAbsent(
        newDoseLogs,
        syncStatus: SyncStatus.pendingCreate,
      );

      _syncSoon();

      final allLogs = [...existingModels, ...newDoseLogs];
      return Result.success(allLogs.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      debugPrint('❌ generateDoseLogs FAILED: $e\n$st');
      return Result.failure('Failed to generate dose logs: $e', st);
    }
  }

  /// Regenerate dose logs for an updated prescription.
  ///
  /// Deletes the pending doses the new schedule no longer has and creates
  /// the ones it adds. A pending dose whose time is still scheduled is kept
  /// as it is: its id would come back unchanged, and deleting it would throw
  /// away a local change still waiting to be pushed.
  @override
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
    String prescriptionId,
  ) async {
    try {
      final prescription = await prescriptionLocal.getPrescriptionById(
        prescriptionId,
      );
      final times = prescription == null
          ? const <DateTime>[]
          : prescription.toDomain().scheduledDoseTimes;
      final stillScheduled = times.map(doseSlotKey).toSet();
      final existing = await localDatasource.getDoseLogsByPrescription(
        prescriptionId,
      );
      // A pending dose stored under a slot's id at another time (an older
      // build wrote some slots hours off) is that slot: generating it again
      // would only bring the same row back from the server.
      final storedKeys = {
        for (final d in existing) doseSlotKey(d.scheduledTime),
      };
      final unmatchedIds = {
        for (final t in times)
          if (!storedKeys.contains(doseSlotKey(t)))
            scheduledDoseId(prescriptionId, t),
      };
      final keepIds = {
        for (final dose in existing)
          if (dose.status == DoseStatus.pending &&
              (stillScheduled.contains(doseSlotKey(dose.scheduledTime)) ||
                  unmatchedIds.contains(dose.id)))
            dose.id,
      };
      // Delete only pending (not yet taken/skipped/missed) dose logs
      await localDatasource.deletePendingByPrescription(
        prescriptionId,
        keepIds: keepIds,
      );

      // Generate fresh dose logs
      return await generateDoseLogsForPrescription(prescriptionId);
    } catch (e, st) {
      debugPrint('❌ regenerateDoseLogs FAILED: $e\n$st');
      return Result.failure('Failed to regenerate dose logs: $e', st);
    }
  }

  /// Asks for a sync cycle without waiting for it.
  void _syncSoon() => requestSyncSoon(_requestSync, 'dose log');
}
