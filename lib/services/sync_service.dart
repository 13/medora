/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase (sync v2, see
/// `docs/superpowers/specs/2026-09-16-sync-v2-design.md`).
///
/// Offline-first. A cycle first asks the server for its sync state
/// (`medora_sync_state`): a project without the sync v2 migration stops the
/// cycle before anything is written ([MissingMigrationException]). Then it
/// pushes, then it pulls.
///
/// - **Push.** A pending row is sent as the columns that differ from its
///   base (the server copy it was last in step with), and only if the server
///   row is still that version. When the server moved on, the two copies are
///   merged column group by column group (`row_merge.dart`) and the rest is
///   sent again. Each attempt carries a write id stored before it is sent, so
///   an answer that never arrived is recognised later. New dose logs go out
///   in batches, inserted only where the server lacks them. Stock changes
///   go out once each, as changes or counts, never as totals, through
///   `apply_stock_change` (`stock_sync.dart`), in the order they were made.
/// - **Pull.** Each table is read from its stored key up to the server's
///   horizon, in pages; a pending local row is merged, not overwritten.
///
/// For medications, treatments, prescriptions and dose logs this is the only
/// push path: the repositories write locally and ask for a [syncAll], which
/// queues behind a running cycle. One [syncAll] re-runs itself at most
/// [SyncService.maxAutomaticReruns] times, then retries once after
/// [SyncService.capRetryDelay]. Every request to the server has a timeout
/// ([SyncService.requestTimeout]) and fails like a network error.
///
/// After an upgrade, the first cycle that runs pulls every table from the
/// beginning once ([SyncCursorStore.startPullRepair]), so every row gets its
/// merge base. Nothing local is wiped.
///
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
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/stock_sync.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_report.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';

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
    required this.syncState,
    StockOutboxLocalDatasource? stockOutbox,
    String Function()? newWriteId,
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
    this.maxPullPages = defaultMaxPullPages,
  }) : _cursors = cursors ?? SyncCursorStore.inMemory(),
       _failures = failures ?? SyncFailureStore.inMemory(),
       _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
       _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
       _onlineStream =
           onlineStream ?? ConnectivityService.instance.onlineStream,
       _now = now ?? DateTime.now,
       stockOutbox = stockOutbox ?? StockOutboxLocalDatasource(),
       _newWriteId = newWriteId ?? const Uuid().v4;

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

  /// `medora_sync_state`; null in local-only mode.
  final SyncStateRemoteDatasource? syncState;

  /// The stock changes waiting to go out.
  final StockOutboxLocalDatasource stockOutbox;

  /// A fresh id for a write attempt, or for a stock change the cycle makes
  /// (a forced count).
  final String Function() _newWriteId;

  /// Called with the signed-in user id after a clean cycle. Belt and braces
  /// for the data-owner bookkeeping the auth screen normally does: if a sign
  /// in ever completed without the screen recording the owner, the first
  /// clean sync records it. The callback itself decides whether an owner is
  /// already stored.
  final Future<void> Function(String userId)? onFirstSuccessfulSync;

  /// Called once per pull that stored a prescription new to this device or
  /// one whose schedule changed, after the dose logs were pulled. The pull
  /// brings the doses the other device generated for it, but not the ones
  /// that device has not sent yet, so this device generates what is still
  /// missing (see `DoseScheduleService.applyPulled`); the sync that asks
  /// for runs as this cycle's re-run and adopts the server's copies. A
  /// failure only logs.
  final Future<void> Function(PulledPrescriptions pulled)?
  onPrescriptionsPulled;

  /// How long one request to the server may take before the cycle gives up
  /// on it. A timed-out request counts as a network failure: the row stays
  /// pending (with backoff) and a table whose fetch timed out keeps its
  /// pull key. The request itself may still land; see [_remote].
  final Duration requestTimeout;

  /// How long after a [syncAll] stopped at [maxAutomaticReruns] the one
  /// delayed retry runs.
  final Duration capRetryDelay;

  /// The most pages one table pulls in one cycle ([pullPageSize] rows each).
  /// A server that keeps answering full pages cannot hold the cycle for
  /// ever; the next cycle continues from the stored pull key.
  final int maxPullPages;

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
      familyRemote != null &&
      syncState != null;

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
      final state = await _remote(syncState!.read());
      // Only here, past every guard in [_run] and the migration check:
      // local-only mode, an offline device, a signed-out user and an
      // unmigrated project leave the repair for a later sync.
      final repairing = await _cursors.startPullRepair();
      await _pushPendingChanges(report);
      final fetchedAll = await _pullAll(
        report,
        force: false,
        horizon: state.horizon,
      );
      // A table whose fetch failed keeps the key of its last stored page
      // (none, if it failed at once), so the next cycle still gets the rest;
      // the repair is recorded once a cycle has fetched every table.
      if (repairing && fetchedAll) await _cursors.finishPullRepair();
    },
    queueable: true,
    retryAfterCap: retryAfterCap,
  );

  /// Push ALL local rows regardless of sync_status: "my copy is the truth".
  Future<SyncReport?> forcePush() => _run('force push', (report) async {
    await _remote(syncState!.read());
    await _pushPendingChanges(report, forceAll: true);
  });

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
    final state = await _remote(syncState!.read());
    await _cursors.clear();
    // Every local row is about to be replaced by the server's, so no row is
    // still waiting to be pushed and no backoff record means anything.
    await _failures.clearAll();
    await AppDatabase.instance.clearAllData();
    await _pullAll(report, force: true, horizon: state.horizon);
    // Everything was pulled from the start: that is the repair.
    await _cursors.finishPullRepair();
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
    if (_disposed) return null;
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
      // A disposed service has been replaced: its cycle ends here, and it
      // arms nothing that would run later next to its successor.
      if (_disposed) break;
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
    final requestedDuringForce = !queueable && _rerunRequested && !_disposed;
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
    } on MissingMigrationException catch (e) {
      debugPrint('Sync: $label stopped — $e');
      report.fatal = '$e';
      report.missingMigration = e.migration;
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
      'deleted ${report.deleted}, merged ${report.merged}, '
      'overwritten ${report.overwritten}, '
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
    if (_disposed) return;
    _idleTimer = Timer(const Duration(seconds: 2), () {
      _idleTimer = null;
      if (_currentState == SyncState.success ||
          _currentState == SyncState.partial) {
        _setState(SyncState.idle);
      }
    });
  }

  // ── Push ───────────────────────────────────────────────────

  /// The per-row sync of one of the four merged tables.
  late final Map<String, TableSync> _tables = {
    if (medicationRemote != null)
      'medications': _tableSync('medications', medicationRemote!.rows),
    if (treatmentRemote != null)
      'treatments': _tableSync('treatments', treatmentRemote!.rows),
    if (prescriptionRemote != null)
      'prescriptions': _tableSync('prescriptions', prescriptionRemote!.rows),
    if (doseLogRemote != null)
      'dose_logs': _tableSync('dose_logs', doseLogRemote!.rows),
  };

  /// `apply_stock_change`, with every request under [requestTimeout].
  late final StockRemote? _stock = medicationRemote == null
      ? null
      : _TimedStockRemote(medicationRemote!.stock, requestTimeout);

  TableSync _tableSync(String table, SyncTable rows) => TableSync(
    table: table,
    remote: _TimedSyncTable(rows, requestTimeout),
    newWriteId: _newWriteId,
    now: _now,
  );

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

    // FK order: Families -> Medications (then their stock changes) ->
    // Treatments -> Prescriptions -> DoseLogs
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

    // Queued before the rows go out: settling a row shows the server's
    // stock with the waiting changes on top, and the count must be what
    // this device holds now.
    if (forceAll) await _queueForcedStock();
    await _pushTable('medications', report, userId, forceAll: forceAll);
    await _pushStock(report);
    await _pushTable('treatments', report, userId, forceAll: forceAll);
    await _pushTable('prescriptions', report, userId, forceAll: forceAll);
    // A dose this device created is only ever inserted where the server does
    // not have it yet, in batches (see [_pushNewDoseLogs]); a forced push is
    // the exception, since it means "my copy is the truth".
    if (!forceAll) await _pushNewDoseLogs(report);
    await _pushTable(
      'dose_logs',
      report,
      userId,
      forceAll: forceAll,
      skipCreates: !forceAll,
    );
  }

  /// Pushes the pending rows of one merged [table] through its [TableSync].
  /// A row under a parent deleted here goes with it, unsent. A dose whose
  /// prescription the server refused this cycle waits for it.
  Future<void> _pushTable(
    String table,
    SyncReport report,
    String userId, {
    required bool forceAll,
    bool skipCreates = false,
  }) async {
    final sync = _tables[table]!;
    final refused = table == 'dose_logs'
        ? await _refusedPrescriptions()
        : const <String>{};
    await _pushBatch(
      table,
      report,
      forceAll
          ? null
          : skipCreates
          ? 'sync_status != ? AND sync_status != ?'
          : 'sync_status != ?',
      forceAll
          ? null
          : skipCreates
          ? [SyncStatus.synced, SyncStatus.pendingCreate]
          : [SyncStatus.synced],
      (row) async {
        // Under a parent deleted here: it goes with it, unsent.
        if (!forceAll && await sync.dropUnderDeletedParent(row)) return false;
        if (refused.contains(row['prescription_id'])) {
          report.skippedBackoff++;
          return false;
        }
        final result = await sync.pushRow(row, userId: userId, force: forceAll);
        _recordConflicts(report, table, row['id']! as String, result.conflicts);
        if (result.outcome == PushOutcome.pending) _rerunRequested = true;
        return true;
      },
    );
  }

  void _recordConflicts(
    SyncReport report,
    String table,
    String id,
    List<MergeConflict> conflicts,
  ) {
    if (conflicts.isEmpty) return;
    report.merged++;
    for (final c in conflicts) {
      report.overwritten.add(
        SyncOverwrite(table, id, c.columns, keptLocal: c.keptLocal),
      );
    }
  }

  /// Prescriptions that are not on the server yet and failed to go there:
  /// their doses would be refused too (sick-branch review m-3 counts a
  /// `pending_update` that never reached the server as well).
  Future<Set<String>> _refusedPrescriptions() async {
    final db = await AppDatabase.instance.database;
    final refused = <String>{};
    for (final p in await db.query(
      'prescriptions',
      columns: ['id'],
      where: 'sync_status != ? AND sync_version IS NULL',
      whereArgs: [SyncStatus.synced],
    )) {
      final id = p['id']! as String;
      if (await _failures.get('prescriptions', id) != null) refused.add(id);
    }
    return refused;
  }

  /// Sends the waiting stock changes, oldest first (design section 7.5).
  ///
  /// A change waits, counted as backing off, while its medication has no
  /// known server version (its create has not settled: until then the
  /// create carries the stock), and while it backs off after a failure. A
  /// change that fails, or waits, holds the later changes of its medication
  /// back for this cycle, so they keep their order; other medications go
  /// on. A failure is recorded under [StockOutboxLocalDatasource.table] and
  /// the op id, and [discardFailedRow] can drop it.
  Future<void> _pushStock(SyncReport report) async {
    final db = await AppDatabase.instance.database;
    final held = <String>{};
    for (final op in await stockOutbox.pending()) {
      final medicationId = op.medicationId;
      if (held.contains(medicationId)) continue;
      final med = await db.query(
        'medications',
        columns: ['sync_version'],
        where: 'id = ?',
        whereArgs: [medicationId],
      );
      if (med.isEmpty || med.first['sync_version'] == null) {
        held.add(medicationId);
        report.skippedBackoff++;
        continue;
      }
      final failure = await _failures.get(
        StockOutboxLocalDatasource.table,
        op.opId,
      );
      if (failure != null && failure.isBackingOffAt(_now())) {
        held.add(medicationId);
        report.skippedBackoff++;
        continue;
      }
      try {
        final status = await sendStockOp(_stock!, op);
        if (status == StockChangeStatus.gone) {
          debugPrint(
            'Sync: stock change ${op.opId} dropped: medication '
            '$medicationId is not on the server',
          );
        } else {
          report.pushed++;
        }
        if (failure != null) {
          await _failures.clear(StockOutboxLocalDatasource.table, op.opId);
        }
      } catch (e) {
        held.add(medicationId);
        await _failures.recordFailure(
          StockOutboxLocalDatasource.table,
          op.opId,
          _now(),
        );
        report.failures.add(
          SyncFailure(StockOutboxLocalDatasource.table, op.opId, 'push: $e'),
        );
      }
    }
  }

  /// A forced push sends every quantity here as a count, after the changes
  /// still waiting: "my copy is the truth" holds for the stock too.
  Future<void> _queueForcedStock() async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final meds = await txn.query(
        'medications',
        columns: ['id', 'quantity'],
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.pendingDelete],
      );
      for (final m in meds) {
        await StockOutboxLocalDatasource.enqueue(
          txn,
          StockOp(
            opId: _newWriteId(),
            medicationId: m['id']! as String,
            setTo: (m['quantity'] as int?) ?? 0,
            createdAt: _now(),
          ),
        );
      }
    });
  }

  /// How many new dose logs one request inserts. The read-back lists their
  /// ids in the URL, which keeps it well under common URL limits.
  static const doseLogInsertBatchSize = 100;

  /// Pushes the `pending_create` dose logs: a generated schedule can be
  /// hundreds of rows, and the same dose (deterministic id) can already be on
  /// the server, taken on another device.
  ///
  /// Per batch: each row gets a write id, stored before the request; one
  /// insert that leaves existing rows alone; then one read of the same ids.
  /// A row the server holds with this device's write id is settled
  /// ([settlePushedRow]); a row someone else wrote is merged (a generated
  /// copy always loses to it). A row missing from the read-back stays
  /// pending with backoff.
  ///
  /// - **The server refuses the batch** ([PostgrestException]): each row is
  ///   sent alone and only the rows the server refuses on their own stay
  ///   pending with backoff.
  /// - **No answer** (a network error or a timeout): every row of the batch
  ///   stays pending with backoff; its write id recognises the insert if it
  ///   landed.
  /// - **A dose whose prescription the server refused** waits, counted as
  ///   backing off, without a failure of its own.
  /// - **A dose whose prescription is deleted here** (its delete could not
  ///   be sent yet) is not sent, and is deleted here with it.
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
    final refused = await _refusedPrescriptions();
    final ready = <Map<String, dynamic>>[];
    final backedOff = <String>{};
    final sync = _tables['dose_logs']!;
    for (final row in rows) {
      final id = row['id'] as String;
      // Its prescription is deleted here: it goes with it, unsent.
      if (await sync.dropUnderDeletedParent(row)) continue;
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
      final batch = await _withWriteIds(
        ready.sublist(
          start,
          (start + doseLogInsertBatchSize).clamp(0, ready.length),
        ),
      );
      if (batch.isEmpty) continue;
      final landed = await _insertNewDoseLogs(batch, report);
      if (landed.isEmpty) continue;
      final List<Map<String, dynamic>> server;
      try {
        server = await _remote(
          doseLogRemote!.rows.fetchMany([
            for (final row in landed) row['id'] as String,
          ]),
        );
      } catch (e) {
        await _failNewDoseLogs(landed, report, e);
        continue;
      }
      final byId = {for (final d in server) d['id'] as String: d};
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
        final bool pending;
        if (RemoteMeta.fromJson(remote).writeId == row['sync_write_id']) {
          pending = await settlePushedRow(
            db,
            'dose_logs',
            pushed: row,
            server: remote,
          );
        } else {
          final applied = await sync.applyPulled(remote);
          _recordConflicts(report, 'dose_logs', id, applied.conflicts);
          pending = await _isLocallyPending('dose_logs', id);
        }
        report.pushed++;
        if (backedOff.contains(id)) await _failures.clear('dose_logs', id);
        if (pending) _rerunRequested = true;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The rows of [rows] that are still new doses here, as stored now, each
  /// with a fresh write id stored first.
  ///
  /// The rows were read before the batches ahead of them went out, and a
  /// person may have changed the schedule meanwhile: a dropped dose that no
  /// server has seen is deleted here at once, and must not be sent after
  /// all (cycle review I-1). A row that is no longer `pending_create` (gone,
  /// or deleted since) is left out, and every other row is sent as it is
  /// now, not as it was read.
  Future<List<Map<String, dynamic>>> _withWriteIds(
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await AppDatabase.instance.database;
    final stamped = <Map<String, dynamic>>[];
    await db.transaction((txn) async {
      for (final row in rows) {
        final writeId = _newWriteId();
        final updated = await txn.update(
          'dose_logs',
          {'sync_write_id': writeId},
          where: 'id = ? AND sync_status = ?',
          whereArgs: [row['id'], SyncStatus.pendingCreate],
        );
        if (updated == 0) continue;
        final current = await txn.query(
          'dose_logs',
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        stamped.add(current.single);
      }
    });
    return stamped;
  }

  /// The insert payload of the local dose row [row]: its data, its write
  /// id, its edit time (the automatic one when it has none) and its column
  /// times. Every payload of a batch has the same keys, as one insert
  /// statement needs; an empty map means the edit time stands for every
  /// column, as it does here.
  static Map<String, Object?> _newDosePayload(Map<String, dynamic> row) => {
    ...localWire('dose_logs', row),
    'write_id': row['sync_write_id'],
    'edited_at': (localRowTime(row) ?? automaticEditedAt).toIso8601String(),
    'field_edited_at': FieldTimes.decode(row['field_edited_at']).toJson(),
  };

  /// Inserts [batch] where the server lacks its rows and returns the rows
  /// the server now has (see [_pushNewDoseLogs]); the others are recorded
  /// as failures.
  Future<List<Map<String, dynamic>>> _insertNewDoseLogs(
    List<Map<String, dynamic>> batch,
    SyncReport report,
  ) async {
    try {
      await _remote(
        doseLogRemote!.rows.insertIfAbsent([
          for (final row in batch) _newDosePayload(row),
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
          doseLogRemote!.rows.insertIfAbsent([_newDosePayload(row)]),
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

  /// The synced tables below each one.
  static const _childTables = {
    'medications': ['prescriptions', 'dose_logs'],
    'treatments': ['prescriptions', 'dose_logs'],
    'prescriptions': ['dose_logs'],
    'dose_logs': <String>[],
  };

  /// Give up on a row that keeps failing to push: replace the local copy with
  /// the server's and forget its backoff. Exposed for the settings failures
  /// dialog.
  ///
  /// The server row is fetched directly and stored with its merge base; a
  /// row the server does not have (or has tombstoned) is deleted locally.
  /// The tables below a discarded row are pulled again from the start.
  /// That is also what discarding a local `pending_delete` means: keep the
  /// server's copy.
  ///
  /// A stuck stock change ([StockOutboxLocalDatasource.table], by op id) is
  /// dropped, and its medication shows the server's stock again, with the
  /// other changes still waiting on top.
  ///
  /// Throws when the fetch fails, leaving the row pending so the caller can
  /// surface the error and the user can try again.
  Future<void> discardFailedRow(String table, String id) async {
    switch (table) {
      case 'medications' || 'treatments' || 'prescriptions' || 'dose_logs':
        final remote = await _remote(_tables[table]!.remote.fetch(id));
        final db = await AppDatabase.instance.database;
        await db.delete(table, where: 'id = ?', whereArgs: [id]);
        if (remote != null && remote['deleted_at'] == null) {
          await _tables[table]!.applyPulled(remote);
        }
        // The local delete took the rows below with it, and a pull may have
        // passed over rows under a parent that was being deleted here: the
        // tables below are pulled again from the start.
        for (final child in _childTables[table]!) {
          await _cursors.resetPullKey(child);
        }
      case StockOutboxLocalDatasource.table:
        await _discardStockChange(id);
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

  /// Drops the stock change [opId]; see [discardFailedRow].
  Future<void> _discardStockChange(String opId) async {
    final op = (await stockOutbox.pending()).where((o) => o.opId == opId);
    if (op.isEmpty) return;
    final medicationId = op.first.medicationId;
    final remote = await _remote(
      _tables['medications']!.remote.fetch(medicationId),
    );
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.delete(
        StockOutboxLocalDatasource.table,
        where: 'op_id = ?',
        whereArgs: [opId],
      );
      if (remote == null || remote['deleted_at'] != null) return;
      await txn.update(
        'medications',
        {
          'quantity': localStock(
            (remote['quantity'] as num?)?.toInt() ?? 0,
            RemoteMeta.fromJson(remote).writeId,
            await StockOutboxLocalDatasource.pendingIn(
              txn,
              medicationId: medicationId,
            ),
          ),
        },
        where: 'id = ?',
        whereArgs: [medicationId],
      );
    });
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

  /// Returns false when a fetch failed, so some table was not read to its
  /// end (or to [maxPullPages]).
  Future<bool> _pullAll(
    SyncReport report, {
    required bool force,
    required int horizon,
  }) async {
    final pulled = PulledPrescriptions();
    final families = await _pullFamilies(report, failFast: force);
    final both = await Future.wait([
      _pullTable('medications', report, force: force, horizon: horizon),
      _pullTable('treatments', report, force: force, horizon: horizon),
    ]);
    final prescriptions = await _pullTable(
      'prescriptions',
      report,
      force: force,
      horizon: horizon,
      pulled: pulled,
    );
    final doses = await _pullTable(
      'dose_logs',
      report,
      force: force,
      horizon: horizon,
      pulled: pulled,
    );
    final hook = onPrescriptionsPulled;
    if (hook != null && !pulled.isEmpty) {
      try {
        await hook(pulled);
      } catch (e) {
        debugPrint('Sync: generating doses for pulled prescriptions: $e');
      }
    }
    return families && !both.contains(false) && prescriptions && doses;
  }

  /// The default for [maxPullPages]: 50,000 rows per table per cycle.
  static const defaultMaxPullPages = 50;

  /// Delta pull for one table: the rows from its stored key up to
  /// [horizon], in pages of [pullPageSize] (see `pullPage`), each applied
  /// through [TableSync.applyPulled].
  ///
  /// The key is stored after every page, so a failure part-way leaves it at
  /// the end of the last page that was fully stored. Once a row fails to
  /// apply, the key stays where it was for the rest of the cycle, so that
  /// row is fetched again. Only an empty page ends the pull
  /// ([afterPullPage]: a project may answer fewer rows than asked for) and
  /// stores the horizon as the next start. A stored key above the horizon
  /// (a restored server) starts the table over.
  ///
  /// A failure to fetch a page is normally recorded and ends this table's
  /// pull. When [force] is set the caller has already cleared the local
  /// database, so the same failure aborts the whole cycle instead.
  ///
  /// A live row whose parent this device lacks ([PullOutcome.orphaned]) is
  /// stored with that parent when the server still has it live; otherwise
  /// the row can never be stored (its parent is deleted) and is passed
  /// over, and the key moves on.
  ///
  /// [pulled] collects prescriptions that are new here or whose schedule
  /// changed.
  Future<bool> _pullTable(
    String table,
    SyncReport report, {
    required bool force,
    required int horizon,
    PulledPrescriptions? pulled,
  }) async {
    final sync = _tables[table]!;
    var after = force ? null : await _cursors.pullKey(table);
    if (after != null && after.xid > horizon) {
      debugPrint(
        'Sync: $table key ${after.xid} is past the horizon $horizon; '
        'pulling it from the start',
      );
      await _cursors.resetPullKey(table);
      after = null;
    }
    var keyHeld = false;
    for (var page = 0; page < maxPullPages; page++) {
      final List<Map<String, dynamic>> rows;
      try {
        rows = await _remote(sync.remote.page(after: after, horizon: horizon));
      } catch (e) {
        report.failures.add(SyncFailure(table, '*', 'pull: $e'));
        if (force) throw _FetchFailedFatally(table, e);
        return false;
      }
      for (final row in rows) {
        final id = row['id'] as String;
        try {
          await _applyPulledRow(table, row, report, pulled);
        } catch (e) {
          keyHeld = true;
          report.failures.add(SyncFailure(table, id, 'apply: $e'));
        }
      }
      final next = afterPullPage(rows, horizon: horizon);
      if (!keyHeld) await _cursors.setPullKey(table, next.key);
      if (next.done) return true;
      after = next.key;
    }
    debugPrint(
      'Sync: $table pull stopped after $maxPullPages pages; '
      'the next cycle continues',
    );
    return true;
  }

  /// Applies the pulled row [row] of [table] and counts it in [report]; a
  /// row whose parents this device lacks is stored after them when the
  /// server still has them live ([_pullTable]). [depth] bounds how far up
  /// that goes (a dose, its prescription, their treatment and medication).
  Future<void> _applyPulledRow(
    String table,
    Map<String, dynamic> row,
    SyncReport report,
    PulledPrescriptions? pulled, {
    int depth = 0,
  }) async {
    final id = row['id'] as String;
    final sync = _tables[table]!;
    final before = pulled != null && table == 'prescriptions'
        ? await prescriptionLocal.getPrescriptionById(id)
        : null;
    var applied = await sync.applyPulled(row);
    if (applied.outcome == PullOutcome.orphaned && depth < 2) {
      var found = false;
      for (final (parent, parentId) in parentsOf(table, row)) {
        if (await _hasLocal(parent, parentId)) continue;
        final remote = await _remote(_tables[parent]!.remote.fetch(parentId));
        if (remote == null || remote['deleted_at'] != null) continue;
        await _applyPulledRow(parent, remote, report, pulled, depth: depth + 1);
        found = true;
      }
      if (found) applied = await sync.applyPulled(row);
    }
    _recordConflicts(report, table, id, applied.conflicts);
    switch (applied.outcome) {
      case PullOutcome.deleted:
        report.deleted++;
      case PullOutcome.kept:
        break;
      case PullOutcome.orphaned:
        debugPrint('Sync: $table/$id belongs under a deleted row; passed over');
      case PullOutcome.inserted || PullOutcome.replaced || PullOutcome.merged:
        report.pulled++;
        if (pulled != null && table == 'prescriptions') {
          await _notePulledPrescription(pulled, id, before);
        }
    }
  }

  /// True when [table] holds a row [id] here, whatever its state.
  Future<bool> _hasLocal(String table, String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Records in [pulled] whether prescription [id] is new here or its
  /// schedule changed from [before].
  Future<void> _notePulledPrescription(
    PulledPrescriptions pulled,
    String id,
    PrescriptionModel? before,
  ) async {
    final after = await prescriptionLocal.getPrescriptionById(id);
    if (after == null) return;
    if (before == null) {
      pulled.added.add(id);
    } else if (_scheduleChanged(before, after)) {
      pulled.changed.add(id);
    }
  }

  /// Returns false when a fetch failed.
  Future<bool> _pullFamilies(SyncReport report, {bool failFast = false}) async {
    try {
      final membership = await _remote(familyRemote!.getCurrentMembership());
      if (membership == null) return true;
      final family = await _remote(
        familyRemote!.getFamilyById(membership.familyId),
      );
      if (family == null) return true;
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
      return true;
    } catch (e) {
      report.failures.add(SyncFailure('families', '*', 'pull: $e'));
      if (failFast) throw _FetchFailedFatally('families', e);
      return false;
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

  // ── Helpers ────────────────────────────────────────────────

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

  /// Set by [dispose]; a disposed service starts no cycle.
  bool _disposed = false;

  void dispose() {
    _disposed = true;
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

/// [StockRemote] with every request under [timeout].
class _TimedStockRemote implements StockRemote {
  _TimedStockRemote(this._inner, this._timeout);

  final StockRemote _inner;
  final Duration _timeout;

  @override
  Future<StockChangeResult> apply(StockOp op) =>
      _inner.apply(op).timeout(_timeout);
}

/// [SyncTable] with every request under [timeout].
class _TimedSyncTable implements SyncTable {
  _TimedSyncTable(this._inner, this._timeout);

  final SyncTable _inner;
  final Duration _timeout;

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) => _inner.page(after: after, horizon: horizon).timeout(_timeout);

  @override
  Future<Map<String, dynamic>?> fetch(String id) =>
      _inner.fetch(id).timeout(_timeout);

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) =>
      _inner.fetchMany(ids).timeout(_timeout);

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => _inner
      .patch(
        id,
        changes,
        ifVersion: ifVersion,
        ifStatus: ifStatus,
        ifLive: ifLive,
      )
      .timeout(_timeout);

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) =>
      _inner.insertIfAbsent(rows).timeout(_timeout);
}
