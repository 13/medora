/// Medora - Dose Log Repository Implementation (Offline-First)
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:uuid/uuid.dart';

class DoseLogRepositoryImpl implements DoseLogRepository {
  DoseLogRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
    required this.prescriptionLocal,
  });

  final DoseLogLocalDatasource localDatasource;
  final DoseLogRemoteDatasource remoteDatasource;
  final PrescriptionLocalDatasource prescriptionLocal;

  static const _uuid = Uuid();

  @override
  Future<Result<List<DoseLog>>> getDoseLogsByPrescription(
      String prescriptionId) async {
    try {
      final models =
          await localDatasource.getDoseLogsByPrescription(prescriptionId);
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
      DateTime start, DateTime end) async {
    try {
      final models = await localDatasource.getDoseLogsByDateRange(start, end);
      return Result.success(models.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to load dose logs: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> addDoseLog(DoseLog doseLog) async {
    try {
      final model = DoseLogModel.fromDomain(doseLog);
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncRemoteInBackground(() => remoteDatasource.addDoseLog(model), model.id);
      return Result.success(doseLog);
    } catch (e, st) {
      return Result.failure('Failed to add dose log: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseTaken(String id) async {
    try {
      final now = DateTime.now();
      await localDatasource.updateStatus(id, 'taken',
          takenTime: now, syncStatus: SyncStatus.pendingUpdate);
      _syncRemoteInBackground(
        () => remoteDatasource.updateDoseLogStatus(id, 'taken', takenTime: now),
        id,
      );
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: now,
        takenTime: now,
        status: DoseStatus.taken,
        updatedAt: now,
      ));
    } catch (e, st) {
      return Result.failure('Failed to mark dose as taken: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) async {
    try {
      final now = DateTime.now();
      await localDatasource.updateStatus(id, 'skipped',
          syncStatus: SyncStatus.pendingUpdate);
      _syncRemoteInBackground(
        () => remoteDatasource.updateDoseLogStatus(id, 'skipped'),
        id,
      );
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: now,
        status: DoseStatus.skipped,
        updatedAt: now,
      ));
    } catch (e, st) {
      return Result.failure('Failed to mark dose as skipped: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) async {
    try {
      final now = DateTime.now();
      await localDatasource.updateStatus(id, 'missed',
          syncStatus: SyncStatus.pendingUpdate);
      _syncRemoteInBackground(
        () => remoteDatasource.updateDoseLogStatus(id, 'missed'),
        id,
      );
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: now,
        status: DoseStatus.missed,
        updatedAt: now,
      ));
    } catch (e, st) {
      return Result.failure('Failed to mark dose as missed: $e', st);
    }
  }

  @override
  Future<Result<List<DoseLog>>> generateDoseLogsForPrescription(
      String prescriptionId) async {
    try {
      final prescription =
          await prescriptionLocal.getPrescriptionById(prescriptionId);
      if (prescription == null) {
        debugPrint('⚠ generateDoseLogs: Prescription $prescriptionId not found in local DB');
        return const Result.failure('Prescription not found');
      }

      final entity = prescription.toDomain();
      final scheduledTimes = entity.scheduledDoseTimes;

      if (scheduledTimes.isEmpty) {
        debugPrint('⚠ generateDoseLogs: No scheduled times generated for prescription $prescriptionId '
            '(scheduleType=${entity.scheduleType}, startTime=${entity.startTime}, '
            'durationDays=${entity.durationDays}, intervalHours=${entity.intervalHours}, '
            'scheduleTimes=${entity.scheduleTimes})');
        return const Result.success([]);
      }

      // Check for existing dose logs to avoid duplicates.
      final existingModels =
          await localDatasource.getDoseLogsByPrescription(prescriptionId);
      final existingTimes = existingModels
          .map((m) => _truncateToMinute(m.scheduledTime))
          .toSet();

      final newDoseLogs = <DoseLogModel>[];
      final now = DateTime.now();
      for (final time in scheduledTimes) {
        if (!existingTimes.contains(_truncateToMinute(time))) {
          newDoseLogs.add(DoseLogModel(
            id: _uuid.v4(),
            prescriptionId: prescriptionId,
            scheduledTime: time,
            status: DoseStatus.pending,
            createdAt: now,
            updatedAt: now,
          ));
        }
      }

      if (newDoseLogs.isEmpty) {
        debugPrint('✅ generateDoseLogs: All ${scheduledTimes.length} dose logs already exist for prescription $prescriptionId');
        return Result.success(existingModels.map((m) => m.toDomain()).toList());
      }

      debugPrint('✅ generateDoseLogs: Creating ${newDoseLogs.length} new dose logs '
          '(${existingModels.length} already exist) for prescription $prescriptionId');

      await localDatasource.upsertBatch(newDoseLogs,
          syncStatus: SyncStatus.pendingCreate);

      // Remote sync in background — don't block
      _syncRemoteBatchInBackground(newDoseLogs);

      final allLogs = [...existingModels, ...newDoseLogs];
      return Result.success(allLogs.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      debugPrint('❌ generateDoseLogs FAILED: $e\n$st');
      return Result.failure('Failed to generate dose logs: $e', st);
    }
  }

  /// Regenerate dose logs for an updated prescription.
  /// Deletes old pending doses and creates new ones.
  @override
  Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
      String prescriptionId) async {
    try {
      // Delete only pending (not yet taken/skipped/missed) dose logs
      await localDatasource.deletePendingByPrescription(prescriptionId);

      // Generate fresh dose logs
      return generateDoseLogsForPrescription(prescriptionId);
    } catch (e, st) {
      debugPrint('❌ regenerateDoseLogs FAILED: $e\n$st');
      return Result.failure('Failed to regenerate dose logs: $e', st);
    }
  }

  /// Fire-and-forget remote sync for a single record.
  void _syncRemoteInBackground(Future<dynamic> Function() remoteFn, String id) {
    if (!ConnectivityService.instance.isOnline) return;
    Future(() async {
      try {
        await remoteFn();
        await localDatasource.markSynced(id);
      } catch (e) {
        debugPrint('⚠ Background sync failed for dose log $id: $e');
      }
    });
  }

  /// Fire-and-forget remote sync for batch records.
  void _syncRemoteBatchInBackground(List<DoseLogModel> models) {
    if (!ConnectivityService.instance.isOnline) return;
    Future(() async {
      try {
        await remoteDatasource.addDoseLogsBatch(models);
        for (final log in models) {
          await localDatasource.markSynced(log.id);
        }
      } catch (e) {
        debugPrint('⚠ Background batch sync failed for dose logs: $e');
      }
    });
  }

  /// Truncate a DateTime to minute precision for consistent comparison.
  static String _truncateToMinute(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}'
        'T${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
