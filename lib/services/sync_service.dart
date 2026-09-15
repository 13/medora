/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase.
///
/// Offline-first. A cycle pushes first, then pulls, and conflicts resolve
/// **last write wins by `updated_at`**, on both sides:
///
/// - On the **push** side a `pending_update` is compared against the remote
///   row's `updated_at` first ([_remoteIsNewer]); a strictly newer remote row
///   is left alone and the local row stays pending, so the pull phase
///   overwrites it. The skip is counted in [SyncReport.skippedStale], not as
///   a failure. `pending_create` rows (the remote row does not exist yet) and
///   `pending_delete` tombstones (a delete always wins) push unconditionally,
///   and `forcePush` skips the comparison entirely.
/// - On the **pull** side [_localPendingIsNewer] keeps a locally pending row
///   that is at least as new as the remote copy.
///
/// Remote tombstones (`deleted_at`) always win and become local hard deletes.
/// Every cycle produces a [SyncReport]; per-row failures never abort the
/// cycle. A row that fails to push repeatedly is backed off exponentially
/// (`SyncFailureStore`) so it stops poisoning every cycle, and the user can
/// give up on it with [discardFailedRow].
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
import 'package:medora/services/sync_failure_store.dart';
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
    SyncFailureStore? failures,
    bool Function()? isOnline,
    String? Function()? currentUserId,
    Stream<bool>? onlineStream,
    DateTime Function()? now,
    this.onFirstSuccessfulSync,
  }) : _cursors = cursors ?? SyncCursorStore.inMemory(),
       _failures = failures ?? SyncFailureStore.inMemory(),
       _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
       _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
       _onlineStream =
           onlineStream ?? ConnectivityService.instance.onlineStream,
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

  /// Called with the signed-in user id after a clean cycle. Belt and braces
  /// for the data-owner bookkeeping the auth screen normally does: if a sign
  /// in ever completed without the screen recording the owner, the first
  /// clean sync records it. The callback itself decides whether an owner is
  /// already stored.
  final Future<void> Function(String userId)? onFirstSuccessfulSync;

  final SyncCursorStore _cursors;
  final SyncFailureStore _failures;
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
  }, queueable: true);

  /// Push ALL local rows regardless of sync_status.
  Future<SyncReport?> forcePush() => _run(
    'force push',
    (report) => _pushPendingChanges(report, forceAll: true),
  );

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
    await _cursors.clear();
    await AppDatabase.instance.clearAllData();
    await _pullAll(report, force: true);
  });

  /// Set when a plain [syncAll] was asked for while a cycle was running; the
  /// running cycle then runs one more before it returns.
  bool _rerunRequested = false;

  /// Runs one cycle. [queueable] marks a request that must not simply be
  /// dropped when a cycle is already running: it is remembered and re-run once
  /// the current cycle finishes, so a change made mid-cycle is not left
  /// unsynced until the next trigger. Force operations are explicit user
  /// actions and are never queued.
  ///
  /// Returns the report of *this* call's own cycle; a queued re-run is what
  /// [lastReport] ends up holding.
  Future<SyncReport?> _run(
    String label,
    Future<void> Function(SyncReport) body, {
    bool queueable = false,
  }) async {
    if (!isAvailable) {
      debugPrint('Sync: $label skipped (local-only mode)');
      return null;
    }
    if (_currentState == SyncState.syncing) {
      if (queueable) {
        debugPrint('Sync: $label queued behind the running cycle');
        _rerunRequested = true;
      }
      return null;
    }
    if (!_isOnline()) {
      debugPrint('Sync: $label skipped (offline)');
      return null;
    }
    if (_currentUserId() == null) {
      debugPrint('Sync: $label skipped (unauthenticated)');
      return null;
    }

    _rerunRequested = false;
    _setState(SyncState.syncing);
    final report = SyncReport(startedAt: _now());
    try {
      await _cycle(label, report, body);
      return report;
    } finally {
      if (_rerunRequested) {
        _rerunRequested = false;
        await syncAll();
      }
    }
  }

  Future<void> _cycle(
    String label,
    SyncReport report,
    Future<void> Function(SyncReport) body,
  ) async {
    try {
      await body(report);
    } on _FetchFailedFatally catch (e) {
      // Force pull already wiped the local database, so a whole-table fetch
      // failure leaves the device with a hole in its data. That is a failed
      // cycle, not a partial one.
      debugPrint('Sync: $label aborted — ${e.table} fetch failed: ${e.cause}');
      report.fatal = '$label: ${e.table} fetch failed';
    } catch (e, st) {
      debugPrint('Sync: fatal error during $label: $e\n$st');
      report.fatal = '$e';
    }
    report.finishedAt = _now();
    final userId = _currentUserId();
    if (report.isClean && userId != null && onFirstSuccessfulSync != null) {
      try {
        await onFirstSuccessfulSync!(userId);
      } catch (e) {
        debugPrint('Sync: recording the data owner failed: $e');
      }
    }
    _lastReport = report;
    debugPrint(
      'Sync: $label done — pushed ${report.pushed}, pulled ${report.pulled}, '
      'deleted ${report.deleted}, skipped-stale ${report.skippedStale}, '
      'skipped-backoff ${report.skippedBackoff}, '
      'failed ${report.failures.length}',
    );
    _setState(
      report.fatal != null
          ? SyncState.error
          : report.hasFailures
          ? SyncState.partial
          : SyncState.success,
    );
    _returnToIdleLater();
  }

  void _returnToIdleLater() {
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (_currentState == SyncState.success ||
          _currentState == SyncState.partial) {
        _setState(SyncState.idle);
      }
    });
  }

  // ── Push ───────────────────────────────────────────────────

  Future<void> _pushPendingChanges(
    SyncReport report, {
    bool forceAll = false,
  }) async {
    final db = await AppDatabase.instance.database;
    final userId = _currentUserId();
    if (userId == null) return;

    final where = forceAll ? null : 'sync_status != ?';
    final whereArgs = forceAll ? null : [SyncStatus.synced];

    // FK order: Families -> Medications -> Treatments -> Prescriptions -> DoseLogs
    await _pushBatch('families', report, where, whereArgs, (row) async {
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        return false; // Task 5
      }
      final model = FamilyModel.fromJson(row);
      await familyRemote!.upsertFamily(model);
      await db.update(
        'families',
        {'sync_status': SyncStatus.synced},
        where: 'id = ?',
        whereArgs: [model.id],
      );
      return true;
    });

    await _pushBatch('family_members', report, where, whereArgs, (row) async {
      final model = FamilyMemberModel.fromJson(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await familyRemote!.removeMember(model.id);
        await familyLocal.hardDeleteMember(model.id);
      } else {
        await familyRemote!.upsertMember(model);
        await db.update(
          'family_members',
          {'sync_status': SyncStatus.synced},
          where: 'id = ?',
          whereArgs: [model.id],
        );
      }
      return true;
    });

    // Families the user left: drop locally once their member rows are gone.
    await _pushBatch(
      'families',
      report,
      'sync_status = ?',
      [SyncStatus.pendingDelete],
      (row) async {
        final id = row['id'] as String;
        final remaining = await db.query(
          'family_members',
          columns: ['id'],
          where: 'family_id = ? AND sync_status = ?',
          whereArgs: [id, SyncStatus.pendingDelete],
        );
        if (remaining.isNotEmpty) return false; // member removal still pending
        await familyLocal.deleteFamily(id);
        return true;
      },
    );

    await _pushBatch('medications', report, where, whereArgs, (row) async {
      final model = MedicationModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await medicationRemote!.deleteMedication(model.id);
        await medicationLocal.hardDelete(model.id);
      } else {
        if (await _remoteIsNewer(
          row,
          medicationRemote!.getUpdatedAt,
          force: forceAll,
        )) {
          report.skippedStale++;
          return false;
        }
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
        if (await _remoteIsNewer(
          row,
          treatmentRemote!.getUpdatedAt,
          force: forceAll,
        )) {
          report.skippedStale++;
          return false;
        }
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
        if (await _remoteIsNewer(
          row,
          prescriptionRemote!.getUpdatedAt,
          force: forceAll,
        )) {
          report.skippedStale++;
          return false;
        }
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
        if (await _remoteIsNewer(
          row,
          doseLogRemote!.getUpdatedAt,
          force: forceAll,
        )) {
          report.skippedStale++;
          return false;
        }
        await doseLogRemote!.upsertDoseLog(model);
        await doseLogLocal.markSynced(model.id);
      }
      return true;
    });
  }

  /// True when the push of [row] must be skipped because the remote copy is
  /// strictly newer than the local edit — the other half of last-write-wins.
  ///
  /// Only `pending_update` rows are compared: a `pending_create` has no remote
  /// row to lose to, a `pending_delete` tombstone always wins, and a forced
  /// push ([forcePush]) is an explicit "my copy is the truth" request. When
  /// either side has no usable `updated_at`, or the remote row is gone, the
  /// push goes ahead.
  Future<bool> _remoteIsNewer(
    Map<String, dynamic> row,
    Future<DateTime?> Function(String id) remoteUpdatedAt, {
    required bool force,
  }) async {
    if (force || row['sync_status'] != SyncStatus.pendingUpdate) return false;
    final localRaw = row['updated_at'] as String?;
    final local = localRaw == null ? null : DateTime.tryParse(localRaw);
    if (local == null) return false;
    final remote = await remoteUpdatedAt(row['id'] as String);
    if (remote == null) return false;
    return remote.toUtc().isAfter(local.toUtc());
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
      final id = '${row['id']}';
      final failure = await _failures.get(table, id);
      if (failure != null && failure.isBackingOffAt(_now())) {
        report.skippedBackoff++;
        continue;
      }
      try {
        if (await processRow(row)) report.pushed++;
        if (failure != null) await _failures.clear(table, id);
      } catch (e) {
        await _failures.recordFailure(table, id, _now());
        report.failures.add(SyncFailure(table, id, 'push: $e'));
      }
      // Yield to the UI every few rows.
      if (i % 5 == 2) await Future<void>.delayed(Duration.zero);
    }
  }

  /// Give up on a row that keeps failing to push: stamp it `synced` locally
  /// so the next pull replaces it with the server copy, and forget its
  /// backoff. Exposed for the settings failures dialog.
  Future<void> discardFailedRow(String table, String id) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      table,
      {'sync_status': SyncStatus.synced},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _failures.clear(table, id);
    debugPrint('Sync: discarded the local change to $table/$id');
  }

  // ── Pull ───────────────────────────────────────────────────

  Future<void> _pullAll(SyncReport report, {required bool force}) async {
    await _pullFamilies(report, failFast: force);
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
  ///
  /// A failure to fetch the table at all is normally recorded and skipped, so
  /// the other tables still sync. When [force] is set the caller has already
  /// cleared the local database, so the same failure is rethrown as
  /// [_FetchFailedFatally] and aborts the whole cycle instead.
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
      if (force) throw _FetchFailedFatally(table, e);
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
      await _cursors.setLastPullAt(
        table,
        newest.subtract(const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _pullFamilies(SyncReport report, {bool failFast = false}) async {
    try {
      final membership = await familyRemote!.getCurrentMembership();
      if (membership == null) return;
      final family = await familyRemote!.getFamilyById(membership.familyId);
      if (family == null) return;
      // A row with unpushed local changes (in particular a pending_delete
      // from "leave family" / "remove member") must not be stamped back to
      // `synced` from the remote copy — that would silently drop the user's
      // change before the next push ever gets to send it.
      if (!await _isLocallyPending('families', family.id)) {
        await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      final members = await familyRemote!.getMembers(family.id);
      for (final m in members) {
        if (await _isLocallyPending('family_members', m.id)) continue;
        await familyLocal.upsertMember(m, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      // Members that vanished remotely are dropped locally (pending local
      // rows are left alone — the next push decides their fate).
      await familyLocal.deleteMembersNotIn(
        family.id,
        members.map((m) => m.id).toSet(),
      );
    } catch (e) {
      report.failures.add(SyncFailure('families', '*', 'pull: $e'));
      if (failFast) throw _FetchFailedFatally('families', e);
    }
  }

  /// True when the local row exists and still has unpushed changes.
  Future<bool> _isLocallyPending(String table, String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.synced],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ── Merge helpers (last-write-wins for locally pending rows) ──

  Future<void> _safeUpsertMedication(
    MedicationModel m, {
    bool force = false,
  }) async {
    if (!force &&
        await _localPendingIsNewer('medications', m.id, m.updatedAt)) {
      return;
    }
    await medicationLocal.upsert(m, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertTreatment(
    TreatmentModel t, {
    bool force = false,
  }) async {
    if (!force && await _localPendingIsNewer('treatments', t.id, t.updatedAt)) {
      return;
    }
    await treatmentLocal.upsert(t, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertPrescription(
    PrescriptionModel p, {
    bool force = false,
  }) async {
    if (!force &&
        await _localPendingIsNewer('prescriptions', p.id, p.updatedAt)) {
      return;
    }
    await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertDoseLog(DoseLogModel d, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('dose_logs', d.id, d.updatedAt)) {
      return;
    }
    await doseLogLocal.upsert(d, syncStatus: SyncStatus.synced);
  }

  /// True when the local row has unpushed changes that are at least as new as
  /// the remote row (so the remote row must not overwrite it). A local
  /// tombstone waiting to be pushed always wins over a live remote row — a
  /// pull must never resurrect a row the user deleted.
  Future<bool> _localPendingIsNewer(
    String table,
    String id,
    DateTime? remoteUpdatedAt,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['updated_at', 'sync_status'],
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.synced],
    );
    if (rows.isEmpty) return false;
    if (rows.first['sync_status'] == SyncStatus.pendingDelete) return true;
    final localRaw = rows.first['updated_at'] as String?;
    final local = localRaw == null ? null : DateTime.tryParse(localRaw);
    if (local == null || remoteUpdatedAt == null) {
      return true; // keep local when unsure
    }
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

/// Internal: a whole-table fetch failed during a cycle that must not continue
/// (force pull, where the local database has already been cleared).
class _FetchFailedFatally implements Exception {
  _FetchFailedFatally(this.table, this.cause);

  final String table;
  final Object cause;

  @override
  String toString() => '_FetchFailedFatally($table): $cause';
}
