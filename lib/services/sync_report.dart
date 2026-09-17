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

/// A group of columns two devices changed differently: the cycle kept one
/// side ([keptLocal] says which) and dropped the other.
class SyncOverwrite {
  const SyncOverwrite(
    this.table,
    this.id,
    this.columns, {
    required this.keptLocal,
  });
  final String table;
  final String id;
  final Set<String> columns;
  final bool keptLocal;

  @override
  String toString() =>
      '$table/$id ${columns.join(',')}: kept ${keptLocal ? 'this device' : 'the server'}';
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

  /// Rows whose pending local change was merged with a newer server copy,
  /// on push or on pull.
  int merged = 0;

  /// Same-field changes one side lost (see the design, section 4.5).
  final List<SyncOverwrite> overwritten = [];

  /// Rows whose push was skipped because they are inside their failure
  /// backoff window (see `SyncFailureStore`). Not a failure either — they are
  /// simply waiting for their next attempt.
  int skippedBackoff = 0;

  final List<SyncFailure> failures = [];

  /// Set when the whole cycle aborted (not a per-row error).
  String? fatal;

  /// The migration file the Supabase project lacks, when that is why the
  /// cycle aborted.
  String? missingMigration;

  bool get hasFailures => failures.isNotEmpty;
  bool get isClean => fatal == null && failures.isEmpty;
}
