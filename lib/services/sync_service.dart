/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase.
/// Offline-first; last-write-wins by `updated_at` for locally pending rows;
/// remote tombstones (`deleted_at`) always win and become local hard deletes.
/// Every cycle produces a [SyncReport]; per-row failures never abort the
/// cycle.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_report.dart';

export 'package:medora/services/sync_report.dart';

/// Current state of the sync process.
enum SyncState { idle, syncing, success, partial, error }

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
    SyncCursorStore? cursors,
    bool Function()? isOnline,
    String? Function()? currentUserId,
    Stream<bool>? onlineStream,
    DateTime Function()? now,
  })  : _cursors = cursors ?? SyncCursorStore.inMemory(),
        _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
        _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
        _onlineStream = onlineStream ?? ConnectivityService.instance.onlineStream,
        _now = now ?? DateTime.now;

  final MedicationLocalDatasource medicationLocal;
  final MedicationRemoteDatasource? medicationRemote;
  final TreatmentLocalDatasource treatmentLocal;
  final TreatmentRemoteDatasource? treatmentRemote;
  final PrescriptionLocalDatasource prescriptionLocal;
  final PrescriptionRemoteDatasource? prescriptionRemote;
  final DoseLogLocalDatasource doseLogLocal;
  final DoseLogRemoteDatasource? doseLogRemote;
  final FamilyLocalDatasource familyLocal;
  final FamilyRemoteDatasource? familyRemote;

  final SyncCursorStore _cursors;
  final bool Function() _isOnline;
  final String? Function() _currentUserId;
  final Stream<bool> _onlineStream;
  final DateTime Function() _now;

  /// True when every remote datasource exists (cloud mode, configured build).
  bool get isAvailable =>
      medicationRemote != null &&
      treatmentRemote != null &&
      prescriptionRemote != null &&
      doseLogRemote != null &&
      familyRemote != null;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;
  SyncState _currentState = SyncState.idle;
  SyncState get currentState => _currentState;

  SyncReport? _lastReport;
  SyncReport? get lastReport => _lastReport;
  DateTime? get lastSyncTime => _lastReport?.finishedAt;

  // ── Auto-sync on reconnect (Task 6 wires the provider) ─────

  StreamSubscription<bool>? _onlineSub;
  Timer? _reconnectTimer;
  bool _wasOnline = true;

  /// Sync once, [debounce] after connectivity comes back. Idempotent.
  void startAutoSync({Duration debounce = const Duration(seconds: 2)}) {
    if (_onlineSub != null) return;
    _wasOnline = _isOnline();
    _onlineSub = _onlineStream.listen((online) {
      final cameOnline = online && !_wasOnline;
      _wasOnline = online;
      if (!cameOnline) return;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(debounce, () => unawaited(syncAll()));
    });
  }

  void stopAutoSync() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _onlineSub?.cancel();
    _onlineSub = null;
  }

  // ── Entry points ───────────────────────────────────────────

  /// Push pending local changes, then pull remote changes. Returns the report,
  /// or null when the cycle was skipped (local-only, offline, signed out, or
  /// already syncing).
  Future<SyncReport?> syncAll() => _run('sync', (report) async {
        await _pushPendingChanges(report);
        await _pullAll(report, force: false);
      });

  /// Push ALL local rows regardless of sync_status.
  Future<SyncReport?> forcePush() =>
      _run('force push', (report) => _pushPendingChanges(report, forceAll: true));

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
        await _cursors.clear();
        await AppDatabase.instance.clearAllData();
        await _pullAll(report, force: true);
      });

  Future<SyncReport?> _run(String label, Future<void> Function(SyncReport) body) async {
    if (!isAvailable) {
      debugPrint('Sync: $label skipped (local-only mode)');
      return null;
    }
    if (_currentState == SyncState.syncing) return null;
    if (!_isOnline()) {
      debugPrint('Sync: $label skipped (offline)');
      return null;
    }
    if (_currentUserId() == null) {
      debugPrint('Sync: $label skipped (unauthenticated)');
      return null;
    }

    _setState(SyncState.syncing);
    final report = SyncReport(startedAt: _now());
    try {
      await body(report);
    } catch (e, st) {
      debugPrint('Sync: fatal error during $label: $e\n$st');
      report.fatal = '$e';
    }
    report.finishedAt = _now();
    _lastReport = report;
    debugPrint('Sync: $label done — pushed ${report.pushed}, pulled ${report.pulled}, '
        'deleted ${report.deleted}, failed ${report.failures.length}');
    _setState(report.fatal != null
        ? SyncState.error
        : report.hasFailures
            ? SyncState.partial
            : SyncState.success);
    _returnToIdleLater();
    return report;
  }

  void _returnToIdleLater() {
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (_currentState == SyncState.success || _currentState == SyncState.partial) {
        _setState(SyncState.idle);
      }
    });
  }

  // ── Push ───────────────────────────────────────────────────

  Future<void> _pushPendingChanges(SyncReport report, {bool forceAll = false}) async {
    final db = await AppDatabase.instance.database;
    final userId = _currentUserId();
    if (userId == null) return;

    final where = forceAll ? null : 'sync_status != ?';
    final whereArgs = forceAll ? null : [SyncStatus.synced];

    // FK order: Families -> Medications -> Treatments -> Prescriptions -> DoseLogs
    await _pushBatch('families', report, where, whereArgs, (row) async {
      if (row['sync_status'] == SyncStatus.pendingDelete) return false; // Task 5
      final model = FamilyModel.fromJson(row);
      await familyRemote!.upsertFamily(model);
      await db.update('families', {'sync_status': SyncStatus.synced},
          where: 'id = ?', whereArgs: [model.id]);
      return true;
    });

    await _pushBatch('family_members', report, where, whereArgs, (row) async {
      final model = FamilyMemberModel.fromJson(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await familyRemote!.removeMember(model.id);
        await familyLocal.hardDeleteMember(model.id);
      } else {
        await familyRemote!.upsertMember(model);
        await db.update('family_members', {'sync_status': SyncStatus.synced},
            where: 'id = ?', whereArgs: [model.id]);
      }
      return true;
    });

    // Families the user left: drop locally once their member rows are gone.
    await _pushBatch('families', report, 'sync_status = ?', [SyncStatus.pendingDelete],
        (row) async {
      final id = row['id'] as String;
      final remaining = await db.query('family_members',
          columns: ['id'],
          where: 'family_id = ? AND sync_status = ?',
          whereArgs: [id, SyncStatus.pendingDelete]);
      if (remaining.isNotEmpty) return false; // member removal still pending
      await familyLocal.deleteFamily(id);
      return true;
    });

    await _pushBatch('medications', report, where, whereArgs, (row) async {
      final model = MedicationModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await medicationRemote!.deleteMedication(model.id);
        await medicationLocal.hardDelete(model.id);
      } else {
        await medicationRemote!.upsertMedication(model);
        await medicationLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('treatments', report, where, whereArgs, (row) async {
      final model = TreatmentModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await treatmentRemote!.deleteTreatment(model.id);
        await treatmentLocal.hardDelete(model.id);
      } else {
        await treatmentRemote!.upsertTreatment(model);
        await treatmentLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('prescriptions', report, where, whereArgs, (row) async {
      final model = PrescriptionModel.fromLocalMap(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await prescriptionRemote!.deletePrescription(model.id);
        await prescriptionLocal.hardDelete(model.id);
      } else {
        await prescriptionRemote!.upsertPrescription(model);
        await prescriptionLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('dose_logs', report, where, whereArgs, (row) async {
      final model = DoseLogModel.fromLocalMap(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await doseLogRemote!.deleteDoseLog(model.id);
        await doseLogLocal.hardDelete(model.id);
      } else {
        await doseLogRemote!.upsertDoseLog(model);
        await doseLogLocal.markSynced(model.id);
      }
      return true;
    });
  }

  /// Runs [processRow] per row; a thrown error becomes a [SyncFailure] and the
  /// batch continues. [processRow] returns false when the row was skipped
  /// (not counted).
  Future<void> _pushBatch(
    String table,
    SyncReport report,
    String? where,
    List<dynamic>? whereArgs,
    Future<bool> Function(Map<String, dynamic>) processRow,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table, where: where, whereArgs: whereArgs);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      try {
        if (await processRow(row)) report.pushed++;
      } catch (e) {
        report.failures.add(SyncFailure(table, '${row['id']}', 'push: $e'));
      }
      // Yield to the UI every few rows.
      if (i % 5 == 2) await Future<void>.delayed(Duration.zero);
    }
  }

  // ── Pull ───────────────────────────────────────────────────

  Future<void> _pullAll(SyncReport report, {required bool force}) async {
    await _pullFamilies(report);
    await Future.wait([
      _pullTable<MedicationModel>(
        table: 'medications',
        report: report,
        force: force,
        fetch: (since) => medicationRemote!.getMedicationsSince(since),
        idOf: (m) => m.id,
        updatedAtOf: (m) => m.updatedAt,
        deletedAtOf: (m) => m.deletedAt,
        delete: medicationLocal.hardDelete,
        upsert: (m) => _safeUpsertMedication(m, force: force),
      ),
      _pullTable<TreatmentModel>(
        table: 'treatments',
        report: report,
        force: force,
        fetch: (since) => treatmentRemote!.getTreatmentsSince(since),
        idOf: (t) => t.id,
        updatedAtOf: (t) => t.updatedAt,
        deletedAtOf: (t) => t.deletedAt,
        delete: treatmentLocal.hardDelete,
        upsert: (t) => _safeUpsertTreatment(t, force: force),
      ),
    ]);
    await _pullTable<PrescriptionModel>(
      table: 'prescriptions',
      report: report,
      force: force,
      fetch: (since) => prescriptionRemote!.getPrescriptionsSince(since),
      idOf: (p) => p.id,
      updatedAtOf: (p) => p.updatedAt,
      deletedAtOf: (p) => p.deletedAt,
      delete: prescriptionLocal.hardDelete,
      upsert: (p) => _safeUpsertPrescription(p, force: force),
    );
    await _pullTable<DoseLogModel>(
      table: 'dose_logs',
      report: report,
      force: force,
      fetch: (since) => doseLogRemote!.getDoseLogsSince(since),
      idOf: (d) => d.id,
      updatedAtOf: (d) => d.updatedAt,
      deletedAtOf: (d) => d.deletedAt,
      delete: doseLogLocal.hardDelete,
      upsert: (d) => _safeUpsertDoseLog(d, force: force),
    );
  }

  /// Delta pull for one table: asks the remote only for rows newer than the
  /// stored cursor, applies tombstones as hard deletes, and advances the
  /// cursor (with a 1 s overlap) to the newest `updated_at` it saw.
  Future<void> _pullTable<T>({
    required String table,
    required SyncReport report,
    required bool force,
    required Future<List<T>> Function(DateTime? since) fetch,
    required String Function(T) idOf,
    required DateTime? Function(T) updatedAtOf,
    required DateTime? Function(T) deletedAtOf,
    required Future<void> Function(String id) delete,
    required Future<void> Function(T row) upsert,
  }) async {
    final since = force ? null : await _cursors.lastPullAt(table);
    final List<T> rows;
    try {
      rows = await fetch(since);
    } catch (e) {
      report.failures.add(SyncFailure(table, '*', 'pull: $e'));
      return;
    }
    DateTime? newest;
    var anyFailure = false;
    for (final row in rows) {
      try {
        if (deletedAtOf(row) != null) {
          await delete(idOf(row));
          report.deleted++;
        } else {
          await upsert(row);
        }
        report.pulled++;
      } catch (e) {
        anyFailure = true;
        report.failures.add(SyncFailure(table, idOf(row), 'apply: $e'));
      }
      final u = updatedAtOf(row)?.toUtc();
      if (u != null && (newest == null || u.isAfter(newest))) newest = u;
    }
    if (newest != null && !anyFailure) {
      await _cursors.setLastPullAt(table, newest.subtract(const Duration(seconds: 1)));
    }
  }

  Future<void> _pullFamilies(SyncReport report) async {
    try {
      final membership = await familyRemote!.getCurrentMembership();
      if (membership == null) return;
      final family = await familyRemote!.getFamilyById(membership.familyId);
      if (family == null) return;
      await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
      report.pulled++;
      final members = await familyRemote!.getMembers(family.id);
      for (final m in members) {
        await familyLocal.upsertMember(m, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      // Members that vanished remotely are dropped locally (pending local
      // rows are left alone — the next push decides their fate).
      await familyLocal.deleteMembersNotIn(
          family.id, members.map((m) => m.id).toSet());
    } catch (e) {
      report.failures.add(SyncFailure('families', '*', 'pull: $e'));
    }
  }

  // ── Merge helpers (last-write-wins for locally pending rows) ──

  Future<void> _safeUpsertMedication(MedicationModel m, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('medications', m.id, m.updatedAt)) return;
    await medicationLocal.upsert(m, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertTreatment(TreatmentModel t, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('treatments', t.id, t.updatedAt)) return;
    await treatmentLocal.upsert(t, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertPrescription(PrescriptionModel p, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('prescriptions', p.id, p.updatedAt)) return;
    await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertDoseLog(DoseLogModel d, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('dose_logs', d.id, d.updatedAt)) return;
    await doseLogLocal.upsert(d, syncStatus: SyncStatus.synced);
  }

  /// True when the local row has unpushed changes that are at least as new as
  /// the remote row (so the remote row must not overwrite it). A local
  /// tombstone waiting to be pushed always wins over a live remote row — a
  /// pull must never resurrect a row the user deleted.
  Future<bool> _localPendingIsNewer(String table, String id, DateTime? remoteUpdatedAt) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table,
        columns: ['updated_at', 'sync_status'],
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.synced]);
    if (rows.isEmpty) return false;
    if (rows.first['sync_status'] == SyncStatus.pendingDelete) return true;
    final localRaw = rows.first['updated_at'] as String?;
    final local = localRaw == null ? null : DateTime.tryParse(localRaw);
    if (local == null || remoteUpdatedAt == null) return true; // keep local when unsure
    return !remoteUpdatedAt.toUtc().isAfter(local.toUtc());
  }

  void _setState(SyncState state) {
    _currentState = state;
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  void dispose() {
    stopAutoSync();
    if (!_stateController.isClosed) _stateController.close();
  }

  @visibleForTesting
  void debugSetStateForTest(SyncState state) => _setState(state);
}
