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
  })  : _maintenance = maintenance,
        _reminders = reminders,
        _sync = sync,
        _syncDelay = syncDelay;

  final Future<void> Function() _maintenance;
  final Future<void> Function() _reminders;
  final Future<void> Function() _sync;
  final Duration _syncDelay;

  Future<void>? _inFlight;

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
    if (includeSync) {
      if (_syncDelay > Duration.zero) await Future<void>.delayed(_syncDelay);
      await _guard('sync', _sync);
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
