/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase.
///
/// Offline-first. A cycle pushes first, then pulls, and conflicts resolve
/// **last write wins by `updated_at`**, on both sides:
///
/// - On the **push** side a `pending_update` is compared against the remote
///   row's `updated_at` first ([_staleAgainstRemote]); a strictly newer
///   remote row is left alone and the local row stays pending, so the pull
///   phase overwrites it — the pull cursor is rewound far enough to guarantee
///   that ([_skipStale]). The skip is counted in [SyncReport.skippedStale],
///   not as a failure. `pending_create` rows (the remote row does not exist yet) and
///   `pending_delete` tombstones (a delete always wins) push unconditionally,
///   and `forcePush` skips the comparison entirely.
/// - A `pending_create` **dose log** is the exception: a dose has a
///   deterministic id, so the server may already have it, taken on another
///   device. New dose logs are inserted only where the server lacks them, in
///   batches, and the server's rows are then stored locally
///   ([_pushNewDoseLogs]). Generated doses and doses the app marked missed on
///   its own carry the weakest stamps (see `generatedUpdatedAt` and
///   `automaticUpdatedAt`), so any real change wins.
/// - On the **pull** side [_localPendingIsNewer] keeps a locally pending row
///   that is at least as new as the remote copy.
/// - A pushed row is marked synced only if it is still the copy the push
///   read ([_settlePushed]); a row edited meanwhile stays pending and the
///   cycle runs once more.
///
/// For medications, treatments, prescriptions and dose logs this is the only
/// push path: the repositories write locally and ask for a [syncAll], which
/// queues behind a running cycle. One [syncAll] re-runs itself at most
/// [SyncService.maxAutomaticReruns] times, then retries once after
/// [SyncService.capRetryDelay]. Every request to the server has a timeout
/// ([SyncService.requestTimeout]) and fails like a network error.
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
import 'package:medora/data/sync/push_settle.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_report.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

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
    this.onPrescriptionsPulled,
    this.requestTimeout = const Duration(seconds: 30),
    this.capRetryDelay = const Duration(seconds: 15),
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

  /// Called once per pull that stored a prescription new to this device or
  /// one whose schedule changed, after the dose logs were pulled. The doses
  /// the other device generated for it carry the 1970 stamp and never come
  /// with a delta pull, so this device generates its own copies (see
  /// `DoseScheduleService.applyPulled`); the sync they ask for runs as this
  /// cycle's re-run and adopts the server's copies. A failure only logs.
  final Future<void> Function(PulledPrescriptions pulled)?
  onPrescriptionsPulled;

  /// How long one request to the server may take before the cycle gives up
  /// on it. A timed-out request counts as a network failure: the row stays
  /// pending (with backoff) and a table whose fetch timed out keeps its
  /// cursor. The request itself may still land; see [_remote].
  final Duration requestTimeout;

  /// How long after a [syncAll] stopped at [maxAutomaticReruns] the one
  /// delayed retry runs.
  final Duration capRetryDelay;

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
  Timer? _idleTimer;
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
  Future<SyncReport?> syncAll() => _syncAll(retryAfterCap: true);

  Future<SyncReport?> _syncAll({required bool retryAfterCap}) => _run(
    'sync',
    (report) async {
      await _pushPendingChanges(report);
      await _pullAll(report, force: false);
    },
    queueable: true,
    retryAfterCap: retryAfterCap,
  );

  /// Push ALL local rows regardless of sync_status.
  Future<SyncReport?> forcePush() => _run(
    'force push',
    (report) => _pushPendingChanges(report, forceAll: true),
  );

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
    await _cursors.clear();
    // Every local row is about to be replaced by the server's, so no row is
    // still waiting to be pushed and no backoff record means anything.
    await _failures.clearAll();
    await AppDatabase.instance.clearAllData();
    await _pullAll(report, force: true);
  });

  /// How many times one [syncAll] runs another cycle on its own, for rows
  /// still pending after their push or for requests made meanwhile. Past
  /// that, whatever is still pending waits for the next request, so a row
  /// that changes on every cycle cannot keep the service syncing for ever.
  static const maxAutomaticReruns = 3;

  /// Set when a plain [syncAll] was asked for while a cycle was running; the
  /// running cycle then runs one more before it returns.
  bool _rerunRequested = false;

  /// The one delayed [syncAll] armed when a sync stopped at the re-run cap
  /// with work left, so that work is not stranded until the next trigger.
  /// The retry itself never arms another, so this cannot become a loop.
  Timer? _capRetryTimer;

  @visibleForTesting
  bool get hasCapRetryScheduled => _capRetryTimer != null;

  /// Runs one cycle. [queueable] marks a request that must not simply be
  /// dropped when a cycle is already running: it is remembered and re-run once
  /// the current cycle finishes, so a change made mid-cycle is not left
  /// unsynced until the next trigger. Force operations are explicit user
  /// actions and are never queued.
  ///
  /// A sync asked for during a force operation runs as a plain [syncAll]
  /// right after it, before the force operation's future completes.
  ///
  /// Returns the report of *this* call's own first cycle; a queued re-run is
  /// what [lastReport] ends up holding.
  Future<SyncReport?> _run(
    String label,
    Future<void> Function(SyncReport) body, {
    bool queueable = false,
    bool retryAfterCap = false,
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
    // This cycle covers whatever a pending retry was going to send.
    if (retryAfterCap) _cancelCapRetry();
    SyncReport? first;
    var reruns = 0;
    do {
      _rerunRequested = false;
      _setState(SyncState.syncing);
      final report = SyncReport(startedAt: _now());
      first ??= report;
      await _cycle(label, report, body);
      if (!queueable || !_rerunRequested) break;
      // A queued re-run answers to the same guards as a fresh request: if
      // the device went offline or the user signed out while the cycle ran,
      // it is dropped rather than run against nothing.
      if (!_isOnline() || _currentUserId() == null) {
        debugPrint('Sync: queued $label dropped (offline or signed out)');
        _rerunRequested = false;
      } else if (reruns == maxAutomaticReruns) {
        debugPrint(
          'Sync: $label stopped after $reruns re-runs; '
          '${retryAfterCap ? 'retrying in $capRetryDelay' : 'rows still pending wait for the next sync'}',
        );
        _rerunRequested = false;
        if (retryAfterCap) {
          _capRetryTimer ??= Timer(capRetryDelay, () {
            _capRetryTimer = null;
            unawaited(_syncAll(retryAfterCap: false));
          });
        }
      } else {
        reruns++;
      }
    } while (_rerunRequested);
    final requestedDuringForce = !queueable && _rerunRequested;
    _rerunRequested = false;
    // A force operation does not re-run itself, but a sync asked for while
    // it ran (a write, or a row edited while the force push sent it) still
    // has to happen: without this it would wait for the next trigger.
    if (requestedDuringForce) await syncAll();
    return first;
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

  /// Drops a finished cycle's state back to [SyncState.idle] after a moment,
  /// so the UI has time to show the outcome. Cancellable: a new cycle (or
  /// [dispose]) kills the pending timer, otherwise the previous cycle's timer
  /// would fire mid-flight and lie about the current one.
  void _returnToIdleLater() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 2), () {
      _idleTimer = null;
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

    // Families are pushed by two batches: this one sends live rows, and the
    // one after the members finishes the tombstones a "leave family" leaves
    // behind. Tombstones are excluded here by the query rather than skipped
    // inside the callback, so a row the second batch is backing off is not
    // visited twice per cycle — the earlier visit used to clear the very
    // failure record the second batch had just written, and the backoff
    // could never escalate.
    final familyWhere = forceAll
        ? 'sync_status != ?'
        : 'sync_status != ? AND sync_status != ?';
    final familyWhereArgs = forceAll
        ? [SyncStatus.pendingDelete]
        : [SyncStatus.synced, SyncStatus.pendingDelete];

    // FK order: Families -> Medications -> Treatments -> Prescriptions -> DoseLogs
    await _pushBatch('families', report, familyWhere, familyWhereArgs, (
      row,
    ) async {
      final model = FamilyModel.fromJson(row);
      await _remote(familyRemote!.upsertFamily(model));
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
        await _remote(familyRemote!.removeMember(model.id));
        await familyLocal.hardDeleteMember(model.id);
      } else {
        await _remote(familyRemote!.upsertMember(model));
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
        await _remote(medicationRemote!.deleteMedication(model.id));
        await medicationLocal.hardDelete(model.id);
      } else {
        final staleAt = await _staleAgainstRemote(
          row,
          (id) => _remote(medicationRemote!.getUpdatedAt(id)),
          force: forceAll,
        );
        if (staleAt != null) {
          await _skipStale('medications', report, staleAt);
          return false;
        }
        final serverAt = await _remote(
          medicationRemote!.upsertMedication(model),
        );
        await _settlePushed('medications', row, serverAt);
      }
      return true;
    });

    await _pushBatch('treatments', report, where, whereArgs, (row) async {
      final model = TreatmentModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await _remote(treatmentRemote!.deleteTreatment(model.id));
        await treatmentLocal.hardDelete(model.id);
      } else {
        final staleAt = await _staleAgainstRemote(
          row,
          (id) => _remote(treatmentRemote!.getUpdatedAt(id)),
          force: forceAll,
        );
        if (staleAt != null) {
          await _skipStale('treatments', report, staleAt);
          return false;
        }
        final serverAt = await _remote(treatmentRemote!.upsertTreatment(model));
        await _settlePushed('treatments', row, serverAt);
      }
      return true;
    });

    await _pushBatch('prescriptions', report, where, whereArgs, (row) async {
      final model = PrescriptionModel.fromLocalMap(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await _remote(prescriptionRemote!.deletePrescription(model.id));
        await prescriptionLocal.hardDelete(model.id);
      } else {
        final staleAt = await _staleAgainstRemote(
          row,
          (id) => _remote(prescriptionRemote!.getUpdatedAt(id)),
          force: forceAll,
        );
        if (staleAt != null) {
          await _skipStale('prescriptions', report, staleAt);
          return false;
        }
        final serverAt = await _remote(
          prescriptionRemote!.upsertPrescription(model),
        );
        await _settlePushed('prescriptions', row, serverAt);
      }
      return true;
    });

    // A dose this device created is only ever inserted where the server does
    // not have it yet, in batches (see [_pushNewDoseLogs]); a forced push is
    // the exception, since it means "my copy is the truth".
    if (!forceAll) await _pushNewDoseLogs(report);
    await _pushBatch(
      'dose_logs',
      report,
      forceAll ? where : 'sync_status != ? AND sync_status != ?',
      forceAll ? whereArgs : [SyncStatus.synced, SyncStatus.pendingCreate],
      (row) async {
        final model = DoseLogModel.fromLocalMap(row);
        if (row['sync_status'] == SyncStatus.pendingDelete) {
          await _remote(doseLogRemote!.deleteDoseLog(model.id));
          await doseLogLocal.hardDelete(model.id);
        } else {
          final staleAt = await _staleAgainstRemote(
            row,
            (id) => _remote(doseLogRemote!.getUpdatedAt(id)),
            force: forceAll,
          );
          if (staleAt != null) {
            await _skipStale('dose_logs', report, staleAt);
            return false;
          }
          final serverAt = await _remote(doseLogRemote!.upsertDoseLog(model));
          await _settlePushed('dose_logs', row, serverAt);
        }
        return true;
      },
    );
  }

  /// How many new dose logs one request inserts. The read-back lists their
  /// ids in the URL, which keeps it well under common URL limits.
  static const doseLogInsertBatchSize = 100;

  /// Pushes the `pending_create` dose logs: a generated schedule can be
  /// hundreds of rows, and the same dose (deterministic id) can already be on
  /// the server, taken on another device.
  ///
  /// Per batch: one insert that leaves existing rows alone, then one read of
  /// the same ids. Each local row that is still the copy this cycle read is
  /// replaced by the server's row, marked `synced` (or deleted if the server
  /// has a tombstone). A row changed meanwhile stays pending and the cycle
  /// runs again. A row missing from the read-back stays pending with backoff.
  ///
  /// - **The server refuses the batch** ([PostgrestException]): one row can
  ///   do that to the whole statement (a constraint, the foreign key, the
  ///   row-level policy), so each row is sent alone and only the rows the
  ///   server refuses on their own stay pending with backoff.
  /// - **No answer** (a network error or a timeout): every row of the batch
  ///   stays pending with backoff. If the insert did land, the next attempt
  ///   inserts nothing and reads the rows back, so the outcome is the same.
  /// - **A dose whose prescription is new here and was refused this cycle**
  ///   is not sent at all (the server would refuse it for the missing
  ///   prescription); it waits, counted as backing off, without a failure of
  ///   its own.
  ///
  /// A failed batch never stops the batches after it.
  Future<void> _pushNewDoseLogs(SyncReport report) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'dose_logs',
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pendingCreate],
      orderBy: 'scheduled_time',
    );
    final refused = <String>{};
    for (final p in await db.query(
      'prescriptions',
      columns: ['id'],
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pendingCreate],
    )) {
      final id = p['id'] as String;
      if (await _failures.get('prescriptions', id) != null) refused.add(id);
    }
    final ready = <Map<String, dynamic>>[];
    final backedOff = <String>{};
    for (final row in rows) {
      final id = row['id'] as String;
      if (refused.contains(row['prescription_id'])) {
        report.skippedBackoff++;
        continue;
      }
      final failure = await _failures.get('dose_logs', id);
      if (failure != null) {
        if (failure.isBackingOffAt(_now())) {
          report.skippedBackoff++;
          continue;
        }
        backedOff.add(id);
      }
      ready.add(row);
    }
    for (var start = 0; start < ready.length; start += doseLogInsertBatchSize) {
      final batch = ready.sublist(
        start,
        (start + doseLogInsertBatchSize).clamp(0, ready.length),
      );
      final landed = await _insertNewDoseLogs(batch, report);
      if (landed.isEmpty) continue;
      final List<DoseLogModel> server;
      try {
        server = await _remote(
          doseLogRemote!.getDoseLogsByIds([
            for (final row in landed) row['id'] as String,
          ]),
        );
      } catch (e) {
        await _failNewDoseLogs(landed, report, e);
        continue;
      }
      final byId = {for (final d in server) d.id: d};
      for (final row in landed) {
        final id = row['id'] as String;
        final remote = byId[id];
        if (remote == null) {
          await _failures.recordFailure('dose_logs', id, _now());
          report.failures.add(
            SyncFailure(
              'dose_logs',
              id,
              'push: not on the server after insert',
            ),
          );
          continue;
        }
        final settled = remote.deletedAt != null
            ? await doseLogLocal.deletePushedCreate(
                id,
                pushedUpdatedAt: row['updated_at'],
              )
            : await doseLogLocal.adoptPushedCreate(
                remote,
                pushedUpdatedAt: row['updated_at'],
              );
        if (settled) {
          report.pushed++;
          if (backedOff.contains(id)) await _failures.clear('dose_logs', id);
        } else if (await _isLocallyPending('dose_logs', id)) {
          _rerunRequested = true;
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Inserts [batch] where the server lacks its rows and returns the rows
  /// the server now has (see [_pushNewDoseLogs]); the others are recorded
  /// as failures.
  Future<List<Map<String, dynamic>>> _insertNewDoseLogs(
    List<Map<String, dynamic>> batch,
    SyncReport report,
  ) async {
    try {
      await _remote(
        doseLogRemote!.insertDoseLogsIfAbsent([
          for (final row in batch) DoseLogModel.fromLocalMap(row),
        ]),
      );
      return batch;
    } on PostgrestException catch (e) {
      if (batch.length == 1) {
        await _failNewDoseLogs(batch, report, e);
        return const [];
      }
      debugPrint(
        'Sync: the server refused a batch of ${batch.length} dose logs '
        '(${e.code}); sending them one by one',
      );
    } catch (e) {
      await _failNewDoseLogs(batch, report, e);
      return const [];
    }
    final landed = <Map<String, dynamic>>[];
    for (var i = 0; i < batch.length; i++) {
      final row = batch[i];
      try {
        await _remote(
          doseLogRemote!.insertDoseLogsIfAbsent([
            DoseLogModel.fromLocalMap(row),
          ]),
        );
        landed.add(row);
      } on PostgrestException catch (e) {
        await _failNewDoseLogs([row], report, e);
      } catch (e) {
        // No answer: the rest would most likely time out one by one too.
        await _failNewDoseLogs(batch.sublist(i), report, e);
        break;
      }
    }
    return landed;
  }

  Future<void> _failNewDoseLogs(
    List<Map<String, dynamic>> rows,
    SyncReport report,
    Object error,
  ) async {
    for (final row in rows) {
      final id = row['id'] as String;
      await _failures.recordFailure('dose_logs', id, _now());
      report.failures.add(SyncFailure('dose_logs', id, 'push: $error'));
    }
  }

  /// [call] with the cycle's [requestTimeout]. A request that times out
  /// throws [TimeoutException] and is handled like any network error; its
  /// result, if it ever arrives, is ignored, so it never settles a row.
  Future<T> _remote<T>(Future<T> call) => call.timeout(requestTimeout);

  /// Settles a row this cycle has just pushed (see [settlePushedRow]): synced
  /// only if nobody changed it since the push read it. A row edited meanwhile
  /// stays pending, and a plain sync runs once more to send it.
  Future<void> _settlePushed(
    String table,
    Map<String, dynamic> row,
    DateTime? serverUpdatedAt,
  ) async {
    final stillPending = await settlePushedRow(
      await AppDatabase.instance.database,
      table,
      id: row['id'] as String,
      pushedUpdatedAt: row['updated_at'],
      serverUpdatedAt: serverUpdatedAt,
    );
    if (stillPending) _rerunRequested = true;
  }

  /// The remote `updated_at` when the push of [row] must be skipped because
  /// the remote copy is strictly newer than the local edit — the other half
  /// of last-write-wins. Null when the push may go ahead.
  ///
  /// Only `pending_update` rows are compared: a `pending_create` has no remote
  /// row to lose to, a `pending_delete` tombstone always wins, and a forced
  /// push ([forcePush]) is an explicit "my copy is the truth" request. When
  /// either side has no usable `updated_at`, or the remote row is gone, the
  /// push goes ahead.
  static Future<DateTime?> _staleAgainstRemote(
    Map<String, dynamic> row,
    Future<DateTime?> Function(String id) remoteUpdatedAt, {
    required bool force,
  }) async {
    if (force || row['sync_status'] != SyncStatus.pendingUpdate) return null;
    final localRaw = row['updated_at'] as String?;
    final local = localRaw == null ? null : DateTime.tryParse(localRaw);
    if (local == null) return null;
    final remote = await remoteUpdatedAt(row['id'] as String);
    if (remote == null) return null;
    return remote.toUtc().isAfter(local.toUtc()) ? remote.toUtc() : null;
  }

  /// Records a push skipped as stale and makes sure the pull that is supposed
  /// to replace the local row actually re-fetches it.
  ///
  /// The remote `updated_at` is stamped by the server (`BEFORE UPDATE`
  /// trigger) while the cursor tracks rows this device has already seen, so
  /// the cursor can easily sit *past* the remote row that just won: the delta
  /// pull asks for `updated_at > cursor`, would not return it, and the local
  /// row would stay pending for ever. Rewinding the cursor to just before the
  /// winning row's stamp puts it back in the next pull's window.
  Future<void> _skipStale(
    String table,
    SyncReport report,
    DateTime remoteUpdatedAt,
  ) async {
    report.skippedStale++;
    final current = await _cursors.lastPullAt(table);
    // A null cursor already means "fetch everything".
    if (current == null) return;
    final target = remoteUpdatedAt.toUtc().subtract(const Duration(seconds: 1));
    if (target.isBefore(current)) await _cursors.setLastPullAt(table, target);
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
        // Only a row that actually went through is forgiven: a row that was
        // skipped (stale, or waiting for another batch) has proved nothing
        // and must keep whatever backoff it had.
        if (await processRow(row)) {
          report.pushed++;
          if (failure != null) await _failures.clear(table, id);
        }
      } catch (e) {
        await _failures.recordFailure(table, id, _now());
        report.failures.add(SyncFailure(table, id, 'push: $e'));
      }
      // Yield to the UI every few rows.
      if (i % 5 == 2) await Future<void>.delayed(Duration.zero);
    }
  }

  /// Give up on a row that keeps failing to push: replace the local copy with
  /// the server's and forget its backoff. Exposed for the settings failures
  /// dialog.
  ///
  /// Stamping the row `synced` and waiting for a pull to fix it is not enough
  /// — a delta pull only returns rows newer than the table cursor, so the
  /// abandoned local values could survive indefinitely. The server row is
  /// fetched directly instead, and a row the server does not have (or has
  /// tombstoned) is deleted locally. That is also what discarding a local
  /// `pending_delete` means: keep the server's copy.
  ///
  /// Throws when the fetch fails, leaving the row pending so the caller can
  /// surface the error and the user can try again.
  Future<void> discardFailedRow(String table, String id) async {
    switch (table) {
      case 'medications':
        final remote = await medicationRemote!.getMedicationById(id);
        await _replaceLocal(
          remote,
          deletedAt: remote?.deletedAt,
          delete: () => medicationLocal.hardDelete(id),
          upsert: (m) =>
              medicationLocal.upsert(m, syncStatus: SyncStatus.synced),
        );
      case 'treatments':
        final remote = await treatmentRemote!.getTreatmentById(id);
        await _replaceLocal(
          remote,
          deletedAt: remote?.deletedAt,
          delete: () => treatmentLocal.hardDelete(id),
          upsert: (t) =>
              treatmentLocal.upsert(t, syncStatus: SyncStatus.synced),
        );
      case 'prescriptions':
        final remote = await prescriptionRemote!.getPrescriptionById(id);
        await _replaceLocal(
          remote,
          deletedAt: remote?.deletedAt,
          delete: () => prescriptionLocal.hardDelete(id),
          upsert: (p) =>
              prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced),
        );
      case 'dose_logs':
        final remote = await doseLogRemote!.getDoseLogById(id);
        await _replaceLocal(
          remote,
          deletedAt: remote?.deletedAt,
          delete: () => doseLogLocal.hardDelete(id),
          upsert: (d) => doseLogLocal.upsert(d, syncStatus: SyncStatus.synced),
        );
      case 'families':
        final remote = await familyRemote!.getFamilyById(id);
        await _replaceLocal(
          remote,
          deletedAt: null,
          delete: () => familyLocal.deleteFamily(id),
          upsert: (f) =>
              familyLocal.upsertFamily(f, syncStatus: SyncStatus.synced),
        );
      case 'family_members':
        await _discardFailedMember(id);
      default:
        throw ArgumentError.value(table, 'table', 'not a synced table');
    }
    await _failures.clear(table, id);
    debugPrint('Sync: discarded the local change to $table/$id');
  }

  /// Applies the server's copy of a row the user gave up on: a missing or
  /// tombstoned row is deleted locally, anything else is stored as `synced`.
  Future<void> _replaceLocal<T>(
    T? remote, {
    required DateTime? deletedAt,
    required Future<void> Function() delete,
    required Future<void> Function(T row) upsert,
  }) async {
    if (remote == null || deletedAt != null) {
      await delete();
      return;
    }
    await upsert(remote);
  }

  /// Family members have no get-by-id endpoint; the member list of the
  /// family the local row belongs to is the equivalent lookup.
  Future<void> _discardFailedMember(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'family_members',
      columns: ['family_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final familyId = rows.isEmpty ? null : rows.first['family_id'] as String?;
    if (familyId == null) {
      await familyLocal.hardDeleteMember(id);
      return;
    }
    final members = await familyRemote!.getMembers(familyId);
    FamilyMemberModel? remote;
    for (final m in members) {
      if (m.id == id) remote = m;
    }
    if (remote == null) {
      await familyLocal.hardDeleteMember(id);
      return;
    }
    await familyLocal.upsertMember(remote, syncStatus: SyncStatus.synced);
  }

  // ── Pull ───────────────────────────────────────────────────

  Future<void> _pullAll(SyncReport report, {required bool force}) async {
    final pulled = PulledPrescriptions();
    await _pullFamilies(report, failFast: force);
    await Future.wait([
      _pullTable<MedicationModel>(
        table: 'medications',
        report: report,
        force: force,
        fetch: (since) => _remote(medicationRemote!.getMedicationsSince(since)),
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
        fetch: (since) => _remote(treatmentRemote!.getTreatmentsSince(since)),
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
      fetch: (since) =>
          _remote(prescriptionRemote!.getPrescriptionsSince(since)),
      idOf: (p) => p.id,
      updatedAtOf: (p) => p.updatedAt,
      deletedAtOf: (p) => p.deletedAt,
      delete: prescriptionLocal.hardDelete,
      upsert: (p) => _safeUpsertPrescription(p, pulled, force: force),
    );
    await _pullTable<DoseLogModel>(
      table: 'dose_logs',
      report: report,
      force: force,
      fetch: (since) => _remote(doseLogRemote!.getDoseLogsSince(since)),
      idOf: (d) => d.id,
      updatedAtOf: (d) => d.updatedAt,
      deletedAtOf: (d) => d.deletedAt,
      delete: doseLogLocal.hardDelete,
      upsert: (d) => _safeUpsertDoseLog(d, force: force),
    );
    final hook = onPrescriptionsPulled;
    if (hook != null && !pulled.isEmpty) {
      try {
        await hook(pulled);
      } catch (e) {
        debugPrint('Sync: generating doses for pulled prescriptions: $e');
      }
    }
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
      final membership = await _remote(familyRemote!.getCurrentMembership());
      if (membership == null) return;
      final family = await _remote(
        familyRemote!.getFamilyById(membership.familyId),
      );
      if (family == null) return;
      // A row with unpushed local changes (in particular a pending_delete
      // from "leave family" / "remove member") must not be stamped back to
      // `synced` from the remote copy — that would silently drop the user's
      // change before the next push ever gets to send it.
      if (!await _isLocallyPending('families', family.id)) {
        await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      final members = await _remote(familyRemote!.getMembers(family.id));
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

  /// Also records in [pulled] whether the row is new here or its schedule
  /// changed.
  Future<void> _safeUpsertPrescription(
    PrescriptionModel p,
    PulledPrescriptions pulled, {
    bool force = false,
  }) async {
    if (!force &&
        await _localPendingIsNewer('prescriptions', p.id, p.updatedAt)) {
      return;
    }
    final before = await prescriptionLocal.getPrescriptionById(p.id);
    await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
    if (before == null) {
      pulled.added.add(p.id);
    } else if (_scheduleChanged(before, p)) {
      pulled.changed.add(p.id);
    }
  }

  /// True when [after] generates other doses than [before] would.
  static bool _scheduleChanged(
    PrescriptionModel before,
    PrescriptionModel after,
  ) =>
      before.scheduleType != after.scheduleType ||
      before.intervalHours != after.intervalHours ||
      before.durationDays != after.durationDays ||
      before.startTime != after.startTime ||
      before.isActive != after.isActive ||
      !listEquals(before.scheduleTimes, after.scheduleTimes);

  Future<void> _safeUpsertDoseLog(DoseLogModel d, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('dose_logs', d.id, d.updatedAt)) {
      return;
    }
    // An overdue dose this device marked missed is not pushed, so the server
    // still has the pending copy; that copy coming back must not undo it.
    if (!force && await doseLogLocal.isAutomaticallyMissedCopyOf(d)) return;
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
    // A starting cycle outlives the previous one's return-to-idle timer.
    if (state == SyncState.syncing) {
      _idleTimer?.cancel();
      _idleTimer = null;
    }
    _currentState = state;
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  void _cancelCapRetry() {
    _capRetryTimer?.cancel();
    _capRetryTimer = null;
  }

  void dispose() {
    stopAutoSync();
    _cancelCapRetry();
    _idleTimer?.cancel();
    _idleTimer = null;
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
