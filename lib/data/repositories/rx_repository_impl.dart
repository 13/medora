/// Medora - Prescription (Rx) Repository (offline-first).
///
/// Same rules as the other repositories: write locally as pending, then ask
/// for a sync cycle, which is the only push path.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';
import 'package:medora/data/models/rx_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';

class RxRepositoryImpl implements RxRepository {
  RxRepositoryImpl({
    required this.rxLocal,
    required this.dispensingLocal,
    required this.medications,
    this._requestSync,
    this._now = systemNow,
  });

  final RxLocalDatasource rxLocal;
  final RxDispensingLocalDatasource dispensingLocal;
  final MedicationRepository medications;
  final RequestSync? _requestSync;
  final Now _now;

  Future<List<RxWithDispensings>> _withDispensings(List<RxModel> rows) async {
    final all = await dispensingLocal.getForRxIds([for (final r in rows) r.id]);
    return [
      for (final r in rows)
        RxWithDispensings(r.toDomain(), [
          for (final d in all)
            if (d.rxId == r.id) d.toDomain(),
        ]),
    ];
  }

  @override
  Future<Result<List<RxWithDispensings>>> getAll() async {
    try {
      return Result.success(await _withDispensings(await rxLocal.getAll()));
    } catch (e, st) {
      return Result.failure('Failed to load prescriptions: $e', st);
    }
  }

  @override
  Future<Result<RxWithDispensings>> getById(String id) async {
    try {
      final row = await rxLocal.getById(id);
      if (row == null || row.deletedAt != null) {
        return const Result.failure('Prescription not found');
      }
      return Result.success((await _withDispensings([row])).single);
    } catch (e, st) {
      return Result.failure('Failed to load prescription: $e', st);
    }
  }

  @override
  Future<Result<List<RxWithDispensings>>> getForTreatment(
    String treatmentId,
  ) async {
    try {
      return Result.success(
        await _withDispensings(await rxLocal.getForTreatment(treatmentId)),
      );
    } catch (e, st) {
      return Result.failure('Failed to load prescriptions: $e', st);
    }
  }

  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    try {
      final nre = rx.nre;
      if (nre != null) {
        final other = await rxLocal.getByNre(nre);
        if (other != null && other.id != rx.id) {
          return Result.failure('$duplicateNrePrefix${other.id}');
        }
      }
      final previous = await rxLocal.getById(rx.id);
      if (previous?.deletedAt != null) {
        return const Result.failure('Prescription was deleted');
      }
      final now = _now();
      final model = RxModel.fromDomain(
        rx.copyWith(
          createdAt: rx.createdAt ?? previous?.createdAt ?? now,
          updatedAt: nextUpdatedAt(previous?.updatedAt, now),
        ),
      );
      await rxLocal.upsert(
        model,
        syncStatus: previous == null
            ? SyncStatus.pendingCreate
            : SyncStatus.pendingUpdate,
      );
      _syncSoon();
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to save prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteRx(String id) async {
    try {
      // The local FK removes the dispensings only on a hard delete; mark
      // them too, so this device shows none and the server gets their
      // tombstones even if its cascade has not run yet.
      for (final d in await dispensingLocal.getForRx(id)) {
        await dispensingLocal.markDeleted(d.id);
      }
      await rxLocal.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete prescription: $e', st);
    }
  }

  @override
  Future<Result<RedeemOutcome>> redeem(
    String rxId,
    List<RxDispensing> dispensings,
  ) async {
    try {
      final rx = await rxLocal.getById(rxId);
      if (rx == null || rx.deletedAt != null) {
        return const Result.failure('Prescription not found');
      }
      final now = _now();
      for (final d in dispensings) {
        await dispensingLocal.upsert(
          RxDispensingModel.fromDomain(
            d,
          ).copyWithStamps(createdAt: now, updatedAt: now),
          syncStatus: SyncStatus.pendingCreate,
        );
      }
      _syncSoon();
      // Stock after the dispensings are safe: a failed stock change must
      // not lose the record of what was collected.
      final byItem = {for (final i in rx.items) i.id: i};
      var stockFailures = 0;
      for (final d in dispensings) {
        final medicationId = byItem[d.itemId]?.medicationId;
        if (medicationId == null || d.unitsAdded <= 0) continue;
        final added = await medications.updateQuantity(
          medicationId,
          d.unitsAdded,
        );
        if (added.isFailure) {
          stockFailures++;
          debugPrint('Rx: stock not updated for $medicationId');
        }
      }
      return Result.success(RedeemOutcome(stockFailures: stockFailures));
    } catch (e, st) {
      return Result.failure('Failed to record dispensing: $e', st);
    }
  }

  @override
  Future<Result<void>> undoDispensing(String dispensingId) async {
    try {
      await dispensingLocal.markDeleted(dispensingId);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to undo dispensing: $e', st);
    }
  }

  void _syncSoon() => requestSyncSoon(_requestSync, 'prescription');
}
