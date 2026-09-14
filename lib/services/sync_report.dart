/// Medora - Result of one sync cycle.
library;

class SyncFailure {
  const SyncFailure(this.table, this.id, this.error);
  final String table;
  final String id;
  final String error;

  @override
  String toString() => '$table/$id: $error';
}

/// Counters are filled in while the cycle runs; read it through
/// `SyncService.lastReport` only after the cycle has finished.
class SyncReport {
  SyncReport({required this.startedAt});

  final DateTime startedAt;
  DateTime? finishedAt;
  int pushed = 0;
  int pulled = 0;
  int deleted = 0;
  final List<SyncFailure> failures = [];

  /// Set when the whole cycle aborted (not a per-row error).
  String? fatal;

  bool get hasFailures => failures.isNotEmpty;
  bool get isClean => fatal == null && failures.isEmpty;
}
