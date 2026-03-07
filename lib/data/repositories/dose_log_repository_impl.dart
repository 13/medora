/// Medora - Dose Log Repository Implementation (Offline-First)
library;

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
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.addDoseLog(model);
          await localDatasource.markSynced(model.id);
        } catch (_) {}
      }
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
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.updateDoseLogStatus(id, 'taken',
              takenTime: now);
          await localDatasource.markSynced(id);
        } catch (_) {}
      }
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: now,
        takenTime: now,
        status: DoseStatus.taken,
      ));
    } catch (e, st) {
      return Result.failure('Failed to mark dose as taken: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseSkipped(String id) async {
    try {
      await localDatasource.updateStatus(id, 'skipped',
          syncStatus: SyncStatus.pendingUpdate);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.updateDoseLogStatus(id, 'skipped');
          await localDatasource.markSynced(id);
        } catch (_) {}
      }
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: DateTime.now(),
        status: DoseStatus.skipped,
      ));
    } catch (e, st) {
      return Result.failure('Failed to mark dose as skipped: $e', st);
    }
  }

  @override
  Future<Result<DoseLog>> markDoseMissed(String id) async {
    try {
      await localDatasource.updateStatus(id, 'missed',
          syncStatus: SyncStatus.pendingUpdate);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.updateDoseLogStatus(id, 'missed');
          await localDatasource.markSynced(id);
        } catch (_) {}
      }
      return Result.success(DoseLog(
        id: id,
        prescriptionId: '',
        scheduledTime: DateTime.now(),
        status: DoseStatus.missed,
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
        return const Result.failure('Prescription not found');
      }
      final entity = prescription.toDomain();
      final doseLogs = entity.scheduledDoseTimes.map((time) {
        return DoseLogModel(
          id: _uuid.v4(),
          prescriptionId: prescriptionId,
          scheduledTime: time,
          status: DoseStatus.pending,
        );
      }).toList();

      await localDatasource.upsertBatch(doseLogs,
          syncStatus: SyncStatus.pendingCreate);

      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.addDoseLogsBatch(doseLogs);
          for (final log in doseLogs) {
            await localDatasource.markSynced(log.id);
          }
        } catch (_) {}
      }

      return Result.success(doseLogs.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to generate dose logs: $e', st);
    }
  }
}
