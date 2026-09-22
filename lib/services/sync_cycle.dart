/// The sync cycle's state machine: what runs, what is dropped, what is
/// queued, and what the UI is told about it.
///
/// Lifted out of [SyncService] whole. The service knows *what* a cycle does
/// — read the server state, push, pull — and this knows *whether* one may
/// start and what happens around it: the guards (local-only, already
/// running, offline, signed out, disposed), the queued re-run and its cap,
/// the one delayed retry past that cap, the reported state and its return to
/// idle, and auto-sync on reconnect. Everything it needs it is handed, so it
/// holds no datasource and no cursor.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/services/sync_report.dart';

/// What the UI shows for the running or last cycle.
enum SyncState { idle, syncing, success, partial, error }

/// Internal: a whole-table fetch failed during a cycle that must not continue
/// (force pull, where the local database has already been cleared).
class FetchFailedFatally implements Exception {
  FetchFailedFatally(this.table, this.cause);

  final String table;
  final Object cause;

  @override
  String toString() => 'FetchFailedFatally($table): $cause';
}

/// Runs one sync cycle at a time and reports its state.
class SyncCycle {
  SyncCycle({
    required this.isAvailable,
    required this.isOnline,
    required this.currentUserId,
    required this.now,
    required this.onlineStream,
    required this.capRetryDelay,
    this.onFirstSuccessfulSync,
  });

  /// Every remote datasource exists: false in local-only mode, where no
  /// cycle ever starts.
  final bool Function() isAvailable;
  final bool Function() isOnline;
  final String? Function() currentUserId;
  final DateTime Function() now;
  final Stream<bool> onlineStream;

  /// How long after a cycle stopped at the re-run cap with work left the one
  /// delayed retry runs.
  final Duration capRetryDelay;

  /// Called once after the first cycle that finished clean for a user, with
  /// that user's id.
  final Future<void> Function(String userId)? onFirstSuccessfulSync;

  /// A plain sync, as [SyncService] runs it. Set once, right after
  /// construction: the queued re-run and the cap retry both go through it,
  /// and it is the one thing this class cannot be handed at build time
  /// because the service builds this.
  late final Future<void> Function({required bool retryAfterCap}) sync;

  /// How many times one cycle runs another on its own, for rows still pending
  /// after their push or for requests made meanwhile. Past that, whatever is
  /// still pending waits for the next request, so a row that changes on every
  /// cycle cannot keep the service syncing for ever.
  static const maxAutomaticReruns = 3;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;
  SyncState _currentState = SyncState.idle;
  SyncState get currentState => _currentState;

  SyncReport? _lastReport;
  SyncReport? get lastReport => _lastReport;
  DateTime? get lastSyncTime => _lastReport?.finishedAt;

  StreamSubscription<bool>? _onlineSub;
  Timer? _reconnectTimer;
  Timer? _idleTimer;
  bool _wasOnline = true;

  /// Set when a plain sync was asked for while a cycle was running; the
  /// running cycle then runs one more before it returns.
  bool _rerunRequested = false;

  /// The one delayed sync armed when a cycle stopped at the re-run cap with
  /// work left, so that work is not stranded until the next trigger. The
  /// retry itself never arms another, so this cannot become a loop.
  Timer? _capRetryTimer;

  bool get hasCapRetryScheduled => _capRetryTimer != null;

  /// Asks the running cycle for one more pass: a row the push left pending,
  /// or a change made while the cycle ran. Honoured only for a queueable
  /// request, and only up to [maxAutomaticReruns].
  void requestRerun() => _rerunRequested = true;

  /// Set by [dispose]; a disposed cycle starts nothing.
  bool _disposed = false;
  bool get isDisposed => _disposed;

  /// Sync once, [debounce] after connectivity comes back. Idempotent.
  void startAutoSync({Duration debounce = const Duration(seconds: 2)}) {
    if (_onlineSub != null) return;
    _wasOnline = isOnline();
    _onlineSub = onlineStream.listen((online) {
      final cameOnline = online && !_wasOnline;
      _wasOnline = online;
      if (!cameOnline) return;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(
        debounce,
        () => unawaited(sync(retryAfterCap: true)),
      );
    });
  }

  void stopAutoSync() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _onlineSub?.cancel();
    _onlineSub = null;
  }

  /// Runs one cycle. [queueable] marks a request that must not simply be
  /// dropped when a cycle is already running: it is remembered and re-run once
  /// the current cycle finishes, so a change made mid-cycle is not left
  /// unsynced until the next trigger. Force operations are explicit user
  /// actions and are never queued.
  ///
  /// A sync asked for during a force operation runs as a plain sync right
  /// after it, before the force operation's future completes.
  ///
  /// Returns the report of *this* call's own first cycle; a queued re-run is
  /// what [lastReport] ends up holding.
  Future<SyncReport?> run(
    String label,
    Future<void> Function(SyncReport) body, {
    bool queueable = false,
    bool retryAfterCap = false,
  }) async {
    if (_disposed) return null;
    if (!isAvailable()) {
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
    if (!isOnline()) {
      debugPrint('Sync: $label skipped (offline)');
      return null;
    }
    if (currentUserId() == null) {
      debugPrint('Sync: $label skipped (unauthenticated)');
      return null;
    }

    _rerunRequested = false;
    // This cycle covers whatever a pending retry was going to send.
    if (retryAfterCap) cancelCapRetry();
    SyncReport? first;
    var reruns = 0;
    do {
      _rerunRequested = false;
      setState(SyncState.syncing);
      final report = SyncReport(startedAt: now());
      first ??= report;
      await _cycle(label, report, body);
      // A disposed service has been replaced: its cycle ends here, and it
      // arms nothing that would run later next to its successor.
      if (_disposed) break;
      if (!queueable || !_rerunRequested) break;
      // A queued re-run answers to the same guards as a fresh request: if
      // the device went offline or the user signed out while the cycle ran,
      // it is dropped rather than run against nothing.
      if (!isOnline() || currentUserId() == null) {
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
            unawaited(sync(retryAfterCap: false));
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
    if (requestedDuringForce) await sync(retryAfterCap: true);
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
    } on FetchFailedFatally catch (e) {
      // Force pull already wiped the local database, so a whole-table fetch
      // failure leaves the device with a hole in its data. That is a failed
      // cycle, not a partial one.
      debugPrint('Sync: $label aborted — ${e.table} fetch failed: ${e.cause}');
      report.fatal = '$label: ${e.table} fetch failed';
    } catch (e, st) {
      debugPrint('Sync: fatal error during $label: $e\n$st');
      report.fatal = '$e';
    }
    report.finishedAt = now();
    final userId = currentUserId();
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
    setState(
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
        setState(SyncState.idle);
      }
    });
  }

  void setState(SyncState state) {
    // A starting cycle outlives the previous one's return-to-idle timer.
    if (state == SyncState.syncing) {
      _idleTimer?.cancel();
      _idleTimer = null;
    }
    _currentState = state;
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  void cancelCapRetry() {
    _capRetryTimer?.cancel();
    _capRetryTimer = null;
  }

  void dispose() {
    _disposed = true;
    stopAutoSync();
    cancelCapRetry();
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_stateController.isClosed) _stateController.close();
  }
}
