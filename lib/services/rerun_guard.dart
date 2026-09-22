/// One reconcile at a time, and never a dropped request.
///
/// Both schedulers reconcile a booked set of notifications against the set
/// that is now wanted, and both had the same guard around it, written twice:
/// a request that arrives while one is running is remembered, and the
/// running one goes round again before it returns. Without it the startup
/// run and a Settings switch can interleave and leave the snapshot
/// describing a state that was never reached.
///
/// Only the guard is shared. What the two schedulers diff — dose ids and
/// their times, stock alert ids and what each one says — has nothing in
/// common beyond the shape, and folding those together would cost more than
/// the duplication did.
library;

class RerunGuard {
  bool _running = false;
  bool _rerunRequested = false;

  /// True while [run] is inside [once].
  bool get isRunning => _running;

  /// Runs [once], then runs it again for every request that arrived while it
  /// was running (all of them collapse into one re-run, as the work is the
  /// same either way). Returns what the last run returned, or 0 for a
  /// request that was folded into a run already in progress.
  Future<int> run(Future<int> Function() once) async {
    if (_running) {
      _rerunRequested = true;
      return 0;
    }
    _running = true;
    var result = 0;
    try {
      do {
        _rerunRequested = false;
        result = await once();
      } while (_rerunRequested);
      return result;
    } finally {
      _running = false;
    }
  }
}
