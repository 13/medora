/// Medora - Work that runs on app start and on foreground resume.
///
/// Order matters. When a sync runs (cloud mode), it comes first, after a
/// short delay so the first frame is not competing with network work: the
/// pull brings in doses taken on other devices before maintenance marks
/// overdue doses missed. Then maintenance changes dose statuses, reminders
/// are reconciled from the corrected data, and the update check comes last -
/// it is the least urgent of the four.
library;

import 'package:flutter/foundation.dart';

class AppStartupTasks {
  AppStartupTasks({
    required this._maintenance,
    required this._reminders,
    required this._sync,
    required this._syncDelay,
    required this._minSyncInterval,
    bool Function()? syncEnabled,
    this._updateCheck,
    this._minUpdateCheckInterval = const Duration(hours: 24),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _syncEnabled = syncEnabled ?? _always;

  static bool _always() => true;

  final Future<void> Function() _maintenance;
  final Future<void> Function() _reminders;
  final Future<void> Function() _sync;
  final Duration _syncDelay;
  final Duration _minSyncInterval;

  /// False when [_sync] would do nothing (local-only mode): the startup then
  /// neither waits for the sync delay nor runs it.
  final bool Function() _syncEnabled;

  /// Optional: absent on platforms and builds without in-app updates.
  final Future<void> Function()? _updateCheck;

  /// In-process throttle only. Surviving a restart is the notifier's job
  /// (the `update.last_check_at` pref); this just keeps a resume from
  /// checking again minutes later.
  final Duration _minUpdateCheckInterval;
  final DateTime Function() _now;

  Future<void>? _inFlight;
  DateTime? _lastSyncAt;
  DateTime? _lastUpdateCheckAt;

  Future<void> run({bool includeSync = true}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _runOnce(includeSync).whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _runOnce(bool includeSync) async {
    final shouldSync =
        includeSync &&
        _syncEnabled() &&
        (_lastSyncAt == null ||
            _now().difference(_lastSyncAt!) >= _minSyncInterval);
    if (shouldSync) {
      if (_syncDelay > Duration.zero) await Future<void>.delayed(_syncDelay);
      await _guard('sync', _sync);
      _lastSyncAt = _now();
    }
    await _guard('maintenance', _maintenance);
    await _guard('reminders', _reminders);
    final updateCheck = _updateCheck;
    if (updateCheck != null &&
        (_lastUpdateCheckAt == null ||
            _now().difference(_lastUpdateCheckAt!) >=
                _minUpdateCheckInterval)) {
      await _guard('updateCheck', updateCheck);
      _lastUpdateCheckAt = _now();
    }
  }

  Future<void> _guard(String name, Future<void> Function() step) async {
    try {
      await step();
    } catch (e, st) {
      debugPrint('Startup task "$name" failed: $e\n$st');
    }
  }
}
