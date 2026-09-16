/// Medora - How a repository asks for a sync cycle after a local write.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Starts a sync cycle, or queues one behind the cycle already running.
typedef RequestSync = Future<void> Function();

/// Calls [request] without waiting for it, after a local write to [what].
///
/// The sync cycle is the only push path for the tables it serves: a
/// repository writes the row locally as pending and then calls this. A
/// failure, whether thrown or returned, only logs, because the row stays
/// pending for the next cycle. A null [request] means local-only mode, where
/// nothing is pushed.
void requestSyncSoon(RequestSync? request, String what) {
  if (request == null) return;
  unawaited(
    Future.sync(request).catchError((Object e) {
      debugPrint('⚠ Sync request after a $what write failed: $e');
    }),
  );
}
