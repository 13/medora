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
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/models/family_model.dart';
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
    required this.familyLocal,
    required this.familyRemote,
  });

  final MedicationLocalDatasource medicationLocal;
  final MedicationRemoteDatasource medicationRemote;
  final TreatmentLocalDatasource treatmentLocal;
  final TreatmentRemoteDatasource treatmentRemote;
  final PrescriptionLocalDatasource prescriptionLocal;
  final PrescriptionRemoteDatasource prescriptionRemote;
  final DoseLogLocalDatasource doseLogLocal;
  final DoseLogRemoteDatasource doseLogRemote;
  final FamilyLocalDatasource familyLocal;
  final FamilyRemoteDatasource familyRemote;

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

  /// Push ALL local data to Supabase, then pull remote data.
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
    debugPrint('Sync: starting full cycle (user: ${SupabaseConfig.currentUserId})...');

    try {
      // 1. Force push ALL local records to ensure existing data is synced
      // (not just those marked as 'pending')
      await _forcePushAll();

      // 2. Pull remote data
      await _pullFamilies();
      await _pullMedications();
      await _pullTreatments();
      await _pullPrescriptions();
      await _pullDoseLogs();

      _lastSyncTime = DateTime.now();
      debugPrint('Sync: cycle completed successfully at $_lastSyncTime');
      _setState(SyncState.success);

      // Return to idle after a brief success indication
      Future.delayed(const Duration(seconds: 2), () {
        if (_currentState == SyncState.success) {
          _setState(SyncState.idle);
        }
      });
    } catch (e, st) {
      debugPrint('Sync: fatal error during cycle: $e\n$st');
      _setState(SyncState.error);
    }
  }

  /// Pushes all local records to Supabase, regardless of sync_status.
  Future<void> _forcePushAll() async {
    final db = await AppDatabase.instance.database;
    final userId = SupabaseConfig.currentUserId;
    if (userId == null) return;

    // FK order: Families -> Medications -> Treatments -> Prescriptions -> DoseLogs

    // 1. Families
    final families = await db.query('families');
    for (final row in families) {
      try {
        final model = FamilyModel.fromJson(row);
        await familyRemote.createFamily(model);
        await db.update('families', {'sync_status': SyncStatus.synced}, where: 'id = ?', whereArgs: [model.id]);
      } catch (_) {}
    }

    // 2. Medications
    final meds = await db.query('medications');
    for (final row in meds) {
      try {
        final model = MedicationModel.fromLocalMap({...row, 'user_id': userId});
        await medicationRemote.upsertMedication(model);
        await medicationLocal.markSynced(model.id);
      } catch (_) {}
    }

    // 3. Treatments
    final treatments = await db.query('treatments');
    for (final row in treatments) {
      try {
        final model = TreatmentModel.fromLocalMap({...row, 'user_id': userId});
        await treatmentRemote.upsertTreatment(model);
        await treatmentLocal.markSynced(model.id);
      } catch (_) {}
    }

    // 4. Prescriptions
    final prescriptions = await db.query('prescriptions');
    for (final row in prescriptions) {
      try {
        final model = PrescriptionModel.fromLocalMap(row);
        await prescriptionRemote.upsertPrescription(model);
        await prescriptionLocal.markSynced(model.id);
      } catch (_) {}
    }

    // 5. Dose Logs
    final doseLogs = await db.query('dose_logs');
    for (final row in doseLogs) {
      try {
        final model = DoseLogModel.fromLocalMap(row);
        await doseLogRemote.updateDoseLogStatus(
          model.id,
          model.status.name,
          takenTime: model.takenTime,
        );
        await doseLogLocal.markSynced(model.id);
      } catch (_) {}
    }
  }

  // ── Pull remote data ───────────────────────────────────────

  Future<void> _pullFamilies() async {
    try {
      final membership = await familyRemote.getCurrentMembership();
      if (membership != null) {
        final family = await familyRemote.getFamilyById(membership.familyId);
        if (family != null) {
          await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
          final members = await familyRemote.getMembers(family.id);
          for (final m in members) {
            await familyLocal.upsertMember(m, syncStatus: SyncStatus.synced);
          }
        }
      }
    } catch (e) { debugPrint('Sync: pull families error: $e'); }
  }

  Future<void> _pullMedications() async {
    try {
      final remoteMeds = await medicationRemote.getMedications();
      for (final m in remoteMeds) { await _safeUpsertMedication(m); }
    } catch (e) { debugPrint('Sync: pull medications error: $e'); }
  }

  Future<void> _pullTreatments() async {
    try {
      final remote = await treatmentRemote.getTreatments();
      for (final t in remote) { await _safeUpsertTreatment(t); }
    } catch (e) { debugPrint('Sync: pull treatments error: $e'); }
  }

  Future<void> _pullPrescriptions() async {
    try {
      final remote = await prescriptionRemote.getActivePrescriptions();
      for (final p in remote) { await _safeUpsertPrescription(p); }
    } catch (e) { debugPrint('Sync: pull prescriptions error: $e'); }
  }

  Future<void> _pullDoseLogs() async {
    try {
      final remote = await doseLogRemote.getTodaysDoseLogs();
      for (final d in remote) { await doseLogLocal.upsertIfSynced(d); }
    } catch (e) { debugPrint('Sync: pull dose logs error: $e'); }
  }

  void _setState(SyncState state) {
    _currentState = state;
    _stateController.add(state);
  }

  // ── Safe upsert helpers ──

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

  Future<bool> _isLocalPending(String table, String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table, columns: ['sync_status'], where: 'id = ? AND sync_status != ?', whereArgs: [id, SyncStatus.synced]);
    return rows.isNotEmpty;
  }

  void dispose() { _stateController.close(); }
}
