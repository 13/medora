/// Medora - Sync Service
///
/// Handles bidirectional sync between local SQLite and Supabase.
/// Strategy: offline-first, last-write-wins by updated_at timestamp.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/services/connectivity_service.dart';

/// Current state of the sync process.
enum SyncState { idle, syncing, error, success }

class SyncService {
  SyncService({
    required this.medicationLocal,
    required this.medicationRemote,
    required this.treatmentLocal,
    required this.treatmentRemote,
    required this.prescriptionLocal,
    required this.prescriptionRemote,
    required this.doseLogLocal,
    required this.doseLogRemote,
  });

  final MedicationLocalDatasource medicationLocal;
  final MedicationRemoteDatasource medicationRemote;
  final TreatmentLocalDatasource treatmentLocal;
  final TreatmentRemoteDatasource treatmentRemote;
  final PrescriptionLocalDatasource prescriptionLocal;
  final PrescriptionRemoteDatasource prescriptionRemote;
  final DoseLogLocalDatasource doseLogLocal;
  final DoseLogRemoteDatasource doseLogRemote;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;
  SyncState _currentState = SyncState.idle;
  SyncState get currentState => _currentState;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Start listening to connectivity and auto-sync when coming online.
  void startAutoSync() {
    ConnectivityService.instance.onlineStream.listen((isOnline) {
      if (isOnline) {
        syncAll();
      }
    });
  }

  /// Push local changes to Supabase, then pull remote data.
  Future<void> syncAll() async {
    if (_currentState == SyncState.syncing) return;
    if (!ConnectivityService.instance.isOnline) {
      debugPrint('Sync: skipped (offline)');
      return;
    }
    if (!SupabaseConfig.isAuthenticated) {
      debugPrint('Sync: skipped (unauthenticated)');
      return;
    }

    _setState(SyncState.syncing);
    debugPrint('Sync: starting push/pull cycle...');

    try {
      // 1. Push local changes
      await _pushMedications();
      await _pushTreatments();
      await _pushPrescriptions();
      await _pushDoseLogs();

      // 2. Pull remote data
      await _pullMedications();
      await _pullTreatments();
      await _pullPrescriptions();
      await _pullDoseLogs();

      _lastSyncTime = DateTime.now();
      debugPrint('Sync: completed successfully at $_lastSyncTime');
      _setState(SyncState.success);

      // Return to idle after a brief success indication
      Future.delayed(const Duration(seconds: 2), () {
        if (_currentState == SyncState.success) {
          _setState(SyncState.idle);
        }
      });
    } catch (e, st) {
      debugPrint('Sync: error: $e\n$st');
      _setState(SyncState.error);
    }
  }

  // ── Push local changes ─────────────────────────────────────

  Future<void> _pushMedications() async {
    final pending = await medicationLocal.getPendingChanges();
    if (pending.isEmpty) return;
    
    debugPrint('Sync: pushing ${pending.length} medications...');
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          // Use currentUserId if missing locally (e.g. created while offline-unauthenticated)
          final userId = row['user_id'] as String? ?? SupabaseConfig.currentUserId;
          
          final model = MedicationModel.fromLocalMap({
            ...row,
            'user_id': userId,
          });

          if (status == SyncStatus.pendingCreate) {
            await medicationRemote.addMedication(model);
          } else {
            await medicationRemote.updateMedication(model);
          }
          await medicationLocal.markSynced(id);
        } else if (status == SyncStatus.pendingDelete) {
          await medicationRemote.deleteMedication(id);
          await medicationLocal.hardDelete(id);
        }
      } catch (e) {
        debugPrint('Sync: failed to push medication $id: $e');
        // Continue with next record
      }
    }
  }

  Future<void> _pushTreatments() async {
    final pending = await treatmentLocal.getPendingChanges();
    if (pending.isEmpty) return;

    debugPrint('Sync: pushing ${pending.length} treatments...');
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          final userId = row['user_id'] as String? ?? SupabaseConfig.currentUserId;
          
          final model = TreatmentModel.fromJson({
            ...row,
            'user_id': userId,
            'is_active': (row['is_active'] as int? ?? 1) == 1,
          });

          if (status == SyncStatus.pendingCreate) {
            await treatmentRemote.addTreatment(model);
          } else {
            await treatmentRemote.updateTreatment(model);
          }
          await treatmentLocal.markSynced(id);
        } else if (status == SyncStatus.pendingDelete) {
          await treatmentRemote.deleteTreatment(id);
          await treatmentLocal.hardDelete(id);
        }
      } catch (e) {
        debugPrint('Sync: failed to push treatment $id: $e');
      }
    }
  }

  Future<void> _pushPrescriptions() async {
    final pending = await prescriptionLocal.getPendingChanges();
    if (pending.isEmpty) return;

    debugPrint('Sync: pushing ${pending.length} prescriptions...');
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          final model = PrescriptionModel.fromLocalMap(row);
          if (status == SyncStatus.pendingCreate) {
            await prescriptionRemote.addPrescription(model);
          } else {
            await prescriptionRemote.updatePrescription(model);
          }
          await prescriptionLocal.markSynced(id);
        } else if (status == SyncStatus.pendingDelete) {
          await prescriptionRemote.deletePrescription(id);
          await prescriptionLocal.hardDelete(id);
        }
      } catch (e) {
        debugPrint('Sync: failed to push prescription $id: $e');
      }
    }
  }

  Future<void> _pushDoseLogs() async {
    final pending = await doseLogLocal.getPendingChanges();
    if (pending.isEmpty) return;

    debugPrint('Sync: pushing ${pending.length} dose logs...');
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate) {
          final model = DoseLogModel.fromJson({
            ...row,
            'status': row['status'] as String? ?? 'pending',
          });
          await doseLogRemote.addDoseLog(model);
          await doseLogLocal.markSynced(id);
        } else if (status == SyncStatus.pendingUpdate) {
          final doseStatus = row['status'] as String? ?? 'pending';
          await doseLogRemote.updateDoseLogStatus(
            id,
            doseStatus,
            takenTime: row['taken_time'] != null
                ? DateTime.tryParse(row['taken_time'] as String)
                : null,
          );
          await doseLogLocal.markSynced(id);
        }
      } catch (e) {
        debugPrint('Sync: failed to push dose log $id: $e');
      }
    }
  }

  // ── Pull remote data ───────────────────────────────────────

  Future<void> _pullMedications() async {
    try {
      final remoteMeds = await medicationRemote.getMedications();
      for (final m in remoteMeds) {
        await _safeUpsertMedication(m);
      }
    } catch (e) {
      debugPrint('Sync: pull medications error: $e');
    }
  }

  Future<void> _pullTreatments() async {
    try {
      final remote = await treatmentRemote.getTreatments();
      for (final t in remote) {
        await _safeUpsertTreatment(t);
      }
    } catch (e) {
      debugPrint('Sync: pull treatments error: $e');
    }
  }

  Future<void> _pullPrescriptions() async {
    try {
      final remote = await prescriptionRemote.getActivePrescriptions();
      for (final p in remote) {
        await _safeUpsertPrescription(p);
      }
    } catch (e) {
      debugPrint('Sync: pull prescriptions error: $e');
    }
  }

  Future<void> _pullDoseLogs() async {
    try {
      final remote = await doseLogRemote.getTodaysDoseLogs();
      for (final d in remote) {
        await doseLogLocal.upsertIfSynced(d);
      }
    } catch (e) {
      debugPrint('Sync: pull dose logs error: $e');
    }
  }

  void _setState(SyncState state) {
    _currentState = state;
    _stateController.add(state);
  }

  // ── Safe upsert helpers (skip rows with local pending changes) ──

  Future<void> _safeUpsertMedication(MedicationModel m) async {
    if (await _isLocalPending('medications', m.id)) return;
    await medicationLocal.upsert(m, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertTreatment(TreatmentModel t) async {
    if (await _isLocalPending('treatments', t.id)) return;
    await treatmentLocal.upsert(t, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertPrescription(PrescriptionModel p) async {
    if (await _isLocalPending('prescriptions', p.id)) return;
    await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
  }

  /// Check if a local row has unpushed changes.
  Future<bool> _isLocalPending(String table, String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table,
        columns: ['sync_status'],
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.synced]);
    return rows.isNotEmpty;
  }

  void dispose() {
    _stateController.close();
  }
}
