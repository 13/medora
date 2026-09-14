/// Medora - Work that runs on app start and on foreground resume.
///
/// Order matters: maintenance changes dose statuses, reminders are then
/// reconciled from the corrected data, and sync (cloud mode) runs last after
/// a short delay so the first frame is not competing with network work.
library;

import 'package:flutter/foundation.dart';

class AppStartupTasks {
  AppStartupTasks({
    required Future<void> Function() maintenance,
    required Future<void> Function() reminders,
    required Future<void> Function() sync,
    required Duration syncDelay,
    required Duration minSyncInterval,
    DateTime Function()? now,
  }) : _maintenance = maintenance,
       _reminders = reminders,
       _sync = sync,
       _syncDelay = syncDelay,
       _minSyncInterval = minSyncInterval,
       _now = now ?? DateTime.now;

  final Future<void> Function() _maintenance;
  final Future<void> Function() _reminders;
  final Future<void> Function() _sync;
  final Duration _syncDelay;
  final Duration _minSyncInterval;
  final DateTime Function() _now;

  Future<void>? _inFlight;
  DateTime? _lastSyncAt;

  Future<void> run({bool includeSync = true}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _runOnce(includeSync).whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _runOnce(bool includeSync) async {
    await _guard('maintenance', _maintenance);
    await _guard('reminders', _reminders);
    final shouldSync =
        includeSync &&
        (_lastSyncAt == null ||
            _now().difference(_lastSyncAt!) >= _minSyncInterval);
    if (shouldSync) {
      if (_syncDelay > Duration.zero) await Future<void>.delayed(_syncDelay);
      await _guard('sync', _sync);
      _lastSyncAt = _now();
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
