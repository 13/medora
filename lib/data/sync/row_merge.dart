/// Medora - Three-way merge of a synced row (sync v2).
///
/// A pending local copy and the server's copy are merged against the base:
/// the server copy this device was last in step with. Columns that only
/// make sense together form a group; a group only one side changed takes
/// that side, a group both changed takes the later edit. Pure, no I/O.
library;

/// Stamps before this are the app's own changes, never a person's.
final DateTime weakEditCeiling = DateTime.utc(1970, 1, 2);

/// The edit time of a change the app made on its own.
final DateTime automaticEditedAt = DateTime.utc(1970);

/// How one synced table merges.
class MergePolicy {
  const MergePolicy({required this.groups, this.serverOwned = const {}});

  /// Columns that only change together. A column in no group is a group of
  /// its own.
  final List<Set<String>> groups;

  /// Columns the client never writes through a row update; the server's
  /// value is always kept.
  final Set<String> serverOwned;

  /// Keys that are bookkeeping on every table, never merged or diffed.
  static const bookkeeping = {'id', 'user_id', 'updated_at', 'deleted_at'};

  Set<String> _groupOf(String column) =>
      groups.firstWhere((g) => g.contains(column), orElse: () => {column});
}

/// One group the two sides changed differently, and which side was kept.
class MergeConflict {
  const MergeConflict(this.columns, {required this.keptLocal});
  final Set<String> columns;
  final bool keptLocal;

  @override
  String toString() => 'MergeConflict($columns, keptLocal: $keptLocal)';
}

class MergeResult {
  const MergeResult(this.row, this.conflicts);
  final Map<String, Object?> row;
  final List<MergeConflict> conflicts;
}

/// The columns of [local] that differ from [base], bookkeeping and
/// [MergePolicy.serverOwned] left out. A null [base] means "unknown": every
/// column counts as changed.
Set<String> changedColumns(
  Map<String, Object?>? base,
  Map<String, Object?> local,
  MergePolicy policy,
) => {
  for (final key in local.keys)
    if (!MergePolicy.bookkeeping.contains(key) &&
        !policy.serverOwned.contains(key) &&
        (base == null || !base.containsKey(key) || base[key] != local[key]))
      key,
};

/// Merges a local pending copy with the server's.
///
/// Per group: a group only one side changed since [base] takes that side;
/// a group both sides changed to different values takes the side edited
/// later ([localEditedAt] against [remoteEditedAt]; a tie keeps the
/// server's). With no [base] every group counts as changed on both sides.
/// Server-owned and bookkeeping columns always come from [remote].
MergeResult mergeRows({
  required Map<String, Object?>? base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
  required DateTime? localEditedAt,
  required DateTime? remoteEditedAt,
  required MergePolicy policy,
}) {
  final merged = Map<String, Object?>.of(remote);
  final conflicts = <MergeConflict>[];
  final localChanged = changedColumns(base, local, policy);
  final remoteChanged = changedColumns(base, remote, policy);
  final done = <String>{};
  for (final column in localChanged) {
    if (done.contains(column)) continue;
    final group = policy._groupOf(column);
    done.addAll(group);
    final sameValues = group.every((c) => local[c] == remote[c]);
    if (sameValues) continue;
    final remoteTouched = group.any(remoteChanged.contains);
    final takeLocal = !remoteTouched || _isLater(localEditedAt, remoteEditedAt);
    if (remoteTouched) {
      conflicts.add(MergeConflict(group, keptLocal: takeLocal));
    }
    if (takeLocal) {
      for (final c in group) {
        if (local.containsKey(c)) merged[c] = local[c];
      }
    }
  }
  return MergeResult(merged, conflicts);
}

/// True when an edit at [a] beats one at [b]. A change the app made on its
/// own ([a] before [weakEditCeiling]) never beats anything; an unknown [b]
/// loses to any real edit.
///
/// The later device edit wins, capped at the time the server received it
/// (controller decision 1). The server applies the cap: every server copy
/// carries its capped edit time. A local change has not arrived yet, so its
/// cap is a later moment than any server copy's; comparing it uncapped
/// gives the same answer. Both are compared as instants, whatever zone or
/// format they were written in.
bool _isLater(DateTime? a, DateTime? b) {
  if (a == null || a.toUtc().isBefore(weakEditCeiling)) return false;
  if (b == null) return true;
  return a.toUtc().isAfter(b.toUtc());
}

/// True when [a] and [b] hold the same client-written values.
bool sameContent(
  Map<String, Object?> a,
  Map<String, Object?> b,
  MergePolicy policy,
) =>
    changedColumns(a, b, policy).isEmpty &&
    changedColumns(b, a, policy).isEmpty;

/// How each synced table merges (see the design, section 4.5).
const medicationMerge = MergePolicy(
  groups: [
    {'barcode', 'ean'},
  ],
);

const treatmentMerge = MergePolicy(
  groups: [
    {'end_date', 'is_active'},
    {'sick_leave_from', 'sick_leave_to'},
  ],
);

const prescriptionMerge = MergePolicy(
  groups: [
    {
      'schedule_type',
      'interval_hours',
      'duration_days',
      'start_time',
      'schedule_times',
    },
    {'dosage', 'dosage_amount', 'dosage_unit'},
  ],
);

const doseLogMerge = MergePolicy(
  groups: [
    {'status', 'taken_time'},
  ],
);

/// The policy of [table].
MergePolicy mergePolicyOf(String table) => switch (table) {
  'medications' => medicationMerge,
  'treatments' => treatmentMerge,
  'prescriptions' => prescriptionMerge,
  'dose_logs' => doseLogMerge,
  _ => throw ArgumentError.value(table, 'table', 'not a merged table'),
};

/// True when [editedAt] marks a change the app made on its own.
bool isAutomaticEdit(DateTime? editedAt) =>
    editedAt != null && editedAt.toUtc().isBefore(weakEditCeiling);
