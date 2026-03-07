/// Medora - Sync Service
///
/// Handles bidirectional sync between local SQLite and Supabase.
/// Strategy: offline-first, last-write-wins by updated_at timestamp.
library;

import 'dart:async';

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
    if (!ConnectivityService.instance.isOnline) return;

    _setState(SyncState.syncing);

    try {
      await _pushMedications();
      await _pushTreatments();
      await _pushPrescriptions();
      await _pushDoseLogs();

      await _pullMedications();
      await _pullTreatments();
      await _pullPrescriptions();
      await _pullDoseLogs();

      _lastSyncTime = DateTime.now();
      _setState(SyncState.success);

      // Return to idle after a brief success indication
      Future.delayed(const Duration(seconds: 2), () {
        if (_currentState == SyncState.success) {
          _setState(SyncState.idle);
        }
      });
    } catch (e) {
      _setState(SyncState.error);
    }
  }

  // ── Push local changes ─────────────────────────────────────

  Future<void> _pushMedications() async {
    final pending = await medicationLocal.getPendingChanges();
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          final model = MedicationModel(
            id: id,
            userId: row['user_id'] as String?,
            name: row['name'] as String,
            activeIngredients: MedicationModel.parseTags(
                row['active_ingredients'] ?? row['active_ingredient']),
            category: row['category'] as String?,
            symptoms: MedicationModel.parseTags(row['symptoms']),
            patientTags: MedicationModel.parseTags(row['patient_tags']),
            purchaseDate: row['purchase_date'] != null
                ? DateTime.tryParse(row['purchase_date'] as String)
                : null,
            expiryDate: row['expiry_date'] != null
                ? DateTime.tryParse(row['expiry_date'] as String)
                : null,
            quantity: row['quantity'] as int? ?? 0,
            minimumStockLevel: row['minimum_stock_level'] as int? ?? 5,
            storageLocation: row['storage_location'] as String?,
            barcode: row['barcode'] as String?,
            imagePath: row['image_path'] as String?,
            notes: row['notes'] as String?,
          );
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
      } catch (_) {
        // Skip this record, will retry on next sync
      }
    }
  }

  Future<void> _pushTreatments() async {
    final pending = await treatmentLocal.getPendingChanges();
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          final model = TreatmentModel(
            id: id,
            userId: row['user_id'] as String?,
            name: row['name'] as String,
            patientTags: MedicationModel.parseTags(
                row['patient_tags'] ?? row['patient_name']),
            symptomTags: MedicationModel.parseTags(
                row['symptom_tags'] ?? row['symptoms']),
            startDate: DateTime.parse(row['start_date'] as String),
            endDate: row['end_date'] != null
                ? DateTime.tryParse(row['end_date'] as String)
                : null,
            isActive: (row['is_active'] as int? ?? 1) == 1,
            notes: row['notes'] as String?,
          );
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
      } catch (_) {
        // Will retry
      }
    }
  }

  Future<void> _pushPrescriptions() async {
    final pending = await prescriptionLocal.getPendingChanges();
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate ||
            status == SyncStatus.pendingUpdate) {
          final model = PrescriptionModel(
            id: id,
            treatmentId: row['treatment_id'] as String,
            medicationId: row['medication_id'] as String,
            dosage: row['dosage'] as String,
            intervalHours: row['interval_hours'] as int? ?? 8,
            durationDays: row['duration_days'] as int? ?? 7,
            startTime: DateTime.parse(row['start_time'] as String),
            isActive: (row['is_active'] as int? ?? 1) == 1,
            notes: row['notes'] as String?,
          );
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
      } catch (_) {
        // Will retry
      }
    }
  }

  Future<void> _pushDoseLogs() async {
    final pending = await doseLogLocal.getPendingChanges();
    for (final row in pending) {
      final status = row['sync_status'] as String;
      final id = row['id'] as String;
      try {
        if (status == SyncStatus.pendingCreate) {
          final model = DoseLogModel(
            id: id,
            prescriptionId: row['prescription_id'] as String,
            scheduledTime:
                DateTime.parse(row['scheduled_time'] as String),
            takenTime: row['taken_time'] != null
                ? DateTime.tryParse(row['taken_time'] as String)
                : null,
            notes: row['notes'] as String?,
          );
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
      } catch (_) {
        // Will retry
      }
    }
  }

  // ── Pull remote data ───────────────────────────────────────

  Future<void> _pullMedications() async {
    try {
      final remoteMeds = await medicationRemote.getMedications();
      for (final m in remoteMeds) {
        await medicationLocal.upsert(m, syncStatus: SyncStatus.synced);
      }
    } catch (_) {
      // Pull failed, local data remains available
    }
  }

  Future<void> _pullTreatments() async {
    try {
      final remote = await treatmentRemote.getTreatments();
      for (final t in remote) {
        await treatmentLocal.upsert(t, syncStatus: SyncStatus.synced);
      }
    } catch (_) {}
  }

  Future<void> _pullPrescriptions() async {
    try {
      final remote = await prescriptionRemote.getActivePrescriptions();
      for (final p in remote) {
        await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
      }
    } catch (_) {}
  }

  Future<void> _pullDoseLogs() async {
    try {
      final remote = await doseLogRemote.getTodaysDoseLogs();
      for (final d in remote) {
        await doseLogLocal.upsert(d, syncStatus: SyncStatus.synced);
      }
    } catch (_) {}
  }

  void _setState(SyncState state) {
    _currentState = state;
    _stateController.add(state);
  }

  void dispose() {
    _stateController.close();
  }
}

