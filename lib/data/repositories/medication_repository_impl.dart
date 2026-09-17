/// Medora - Medication Repository Implementation (Offline-First)
library;

import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:uuid/uuid.dart';

/// Writes go to the local database only: each one stores the row as pending
/// and asks for a sync cycle, which is the one place that pushes (see
/// `TreatmentRepositoryImpl`).
///
/// A stock change goes out as a change, never as the new total: it waits in
/// the stock outbox with an id the server applies once
/// (`apply_stock_change`), and leaves the row as it is. A quantity typed
/// into the form is a count, sent the same way, so a dose logged on another
/// device meanwhile still applies in the order the server receives the two.
class MedicationRepositoryImpl implements MedicationRepository {
  /// [requestSync] starts (or queues) a sync cycle; it is not awaited and a
  /// failure only logs. Null in local-only mode, where nothing is pushed and
  /// a stock change waits only for a medication the server has seen
  /// ([StockQueueing.ifKnownToServer]).
  ///
  /// [now] is the clock for the stamps a write sets; [newOpId] names a stock
  /// change (a uuid: the server's ledger key).
  MedicationRepositoryImpl({
    required this.localDatasource,
    this._requestSync,
    this._now = systemNow,
    String Function()? newOpId,
  }) : _newOpId = newOpId ?? const Uuid().v4;

  final MedicationLocalDatasource localDatasource;
  final RequestSync? _requestSync;
  final Now _now;
  final String Function() _newOpId;

  StockQueueing get _queueing => _requestSync == null
      ? StockQueueing.ifKnownToServer
      : StockQueueing.always;

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
      final now = _now();
      final model = MedicationModel.fromDomain(
        medication.copyWith(
          updatedAt: now,
          createdAt: medication.createdAt ?? now,
        ),
      );
      await localDatasource.upsert(model, syncStatus: SyncStatus.pendingCreate);
      _syncSoon();
      return Result.success(medication);
    } catch (e, st) {
      return Result.failure('Failed to add medication: $e', st);
    }
  }

  @override
  Future<Result<Medication>> updateMedication(Medication medication) async {
    try {
      final status = await localDatasource.syncStatusOf(medication.id);
      // An edit of a deleted medication would bring it back.
      if (status == SyncStatus.pendingDelete) {
        return const Result.failure('Medication was deleted');
      }
      final previous = await localDatasource.getMedicationById(medication.id);
      final now = _now();
      final model = MedicationModel.fromDomain(
        medication.copyWith(updatedAt: nextUpdatedAt(previous?.updatedAt, now)),
      );
      final counted =
          previous != null && previous.quantity != medication.quantity;
      await localDatasource.upsert(
        model,
        syncStatus: status == null
            ? SyncStatus.pendingCreate
            : MedicationLocalDatasource.editedSyncStatus(status),
        stockOp: counted
            ? StockOp(
                opId: _newOpId(),
                medicationId: medication.id,
                setTo: medication.quantity,
                createdAt: now,
              )
            : null,
        queueing: _queueing,
      );
      _syncSoon();
      return Result.success(medication);
    } catch (e, st) {
      return Result.failure('Failed to update medication: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteMedication(String id) async {
    try {
      await localDatasource.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete medication: $e', st);
    }
  }

  @override
  Future<Result<Medication>> updateQuantity(String id, int delta) async {
    try {
      // Only the quantity is written, and the change waits as a change: it
      // neither drops another column nor brings a deleted medication back.
      final updated = await localDatasource.adjustQuantity(
        id,
        delta,
        opId: _newOpId(),
        queueing: _queueing,
      );
      if (updated == null) {
        return const Result.failure('Medication not found');
      }
      _syncSoon();
      return Result.success(updated.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to update quantity: $e', st);
    }
  }

  @override
  Future<Result<void>> archiveMedication(String id) async {
    try {
      if (!await localDatasource.archiveMedication(id)) {
        return const Result.failure('Medication not found');
      }
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to archive medication: $e', st);
    }
  }

  @override
  Future<Result<void>> unarchiveMedication(String id) async {
    try {
      if (!await localDatasource.unarchiveMedication(id)) {
        return const Result.failure('Medication not found');
      }
      _syncSoon();
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

  /// Asks for a sync cycle without waiting for it.
  void _syncSoon() => requestSyncSoon(_requestSync, 'medication');
}
