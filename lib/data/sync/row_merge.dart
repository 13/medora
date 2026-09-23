/// Medora - Three-way merge of a synced row (sync v2).
///
/// A pending local copy and the server's copy are merged against the base:
/// the server copy this device was last in step with. Columns that only
/// make sense together form a group; a group only one side changed takes
/// that side, a group both changed takes the later edit, judged by the
/// edit times of that group's columns (`field_edited_at`). Pure, no I/O.
library;

import 'package:medora/data/local/field_times.dart';

/// The edit time of a change the app made on its own.
final DateTime automaticEditedAt = FieldTime.automaticChange.at;

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
  static const bookkeeping = bookkeepingColumns;

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
  const MergeResult(
    this.row,
    this.conflicts,
    this.times, {
    this.sendsTimes = false,
  });
  final Map<String, Object?> row;
  final List<MergeConflict> conflicts;

  /// The edit times of [row]: the server's, with this device's for the
  /// columns taken from here.
  final FieldTimes times;

  /// True when a group holds the same values on both sides, but a person
  /// here set them later than the server's times say: [row] equals the
  /// server copy, and still has those times to send.
  final bool sendsTimes;
}

/// The columns of [local] that differ from [base], bookkeeping and
/// [MergePolicy.serverOwned] left out. A null [base] means "unknown": every
/// column counts as changed.
///
/// With [times] (the copy's column times) and [baseTimes] (the base's), a
/// column also counts when a person changed it after the base's change to
/// it, even back to the base's value: that is the latest edit.
Set<String> changedColumns(
  Map<String, Object?>? base,
  Map<String, Object?> local,
  MergePolicy policy, {
  FieldTimes? times,
  FieldTimes? baseTimes,
}) => {
  for (final key in local.keys)
    if (!MergePolicy.bookkeeping.contains(key) &&
        !policy.serverOwned.contains(key) &&
        (base == null ||
            !base.containsKey(key) ||
            !wireValueEquals(base[key], local[key]) ||
            _changedSince(key, times, baseTimes)))
      key,
};

/// True when [times] holds a person's change to [column] later than the
/// change [baseTimes] holds for it.
bool _changedSince(String column, FieldTimes? times, FieldTimes? baseTimes) {
  if (times == null || baseTimes == null) return false;
  if (untimedColumns.contains(column)) return false;
  final now = times.of(column);
  final then = baseTimes.of(column);
  return now != null &&
      then != null &&
      !now.automatic &&
      now.at.isAfter(then.at);
}

/// Merges a local pending copy with the server's.
///
/// A column counts as changed on a side when its value differs from
/// [base], or when that side's time for it is a person's change later than
/// the base's ([baseTimes], when known): a change back to the base's value.
///
/// Per group: a group only one side changed since [base] takes that side;
/// a group both sides changed to different values takes the side whose
/// change to it beats the other's ([beats]): each side's change is the
/// strongest of the times ([localTimes], [remoteTimes]) of the group's
/// columns that side changed. A person's change beats the app's own; two
/// people's changes go by time; a tie keeps the server's. With no [base]
/// every group counts as changed on both sides. Server-owned and
/// bookkeeping columns always come from [remote].
///
/// A group this side changed to the values the server already holds keeps
/// this side's times when a person here made that change after the
/// server's times for the group ([MergeResult.sendsTimes]): setting the
/// same value later is the latest edit, and a third device's older change
/// must lose to it.
///
/// The times a server copy carries are already capped at the moment the
/// server received each change. A local change has not arrived yet, so its
/// cap would be a later moment than any server copy's; comparing it
/// uncapped gives the same answer.
MergeResult mergeRows({
  required Map<String, Object?>? base,
  FieldTimes? baseTimes,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
  required FieldTimes localTimes,
  required FieldTimes remoteTimes,
  required MergePolicy policy,
}) {
  final merged = Map<String, Object?>.of(remote);
  final times = remoteTimes.resolved(remote.keys);
  final conflicts = <MergeConflict>[];
  final localChanged = changedColumns(
    base,
    local,
    policy,
    times: localTimes,
    baseTimes: baseTimes,
  );
  final remoteChanged = changedColumns(
    base,
    remote,
    policy,
    times: remoteTimes,
    baseTimes: baseTimes,
  );
  final done = <String>{};
  var sendsTimes = false;
  for (final column in localChanged) {
    if (done.contains(column)) continue;
    final group = policy._groupOf(column);
    done.addAll(group);
    final sameValues = group.every((c) => wireValueEquals(local[c], remote[c]));
    if (sameValues) {
      // The same values: a person here who set them after the server's
      // change to them made the latest edit of the group (review Minor 1),
      // so this device's times are kept, and sent.
      final here = group.where(localChanged.contains);
      final mine = localTimes.strongestOf(here);
      if (mine != null &&
          !mine.automatic &&
          beats(mine, remoteTimes.strongestOf(group))) {
        for (final c in here) {
          final time = localTimes.of(c);
          if (time != null && !untimedColumns.contains(c)) times[c] = time;
        }
        sendsTimes = true;
      }
      continue;
    }
    final remoteTouched = group.any(remoteChanged.contains);
    final takeLocal =
        !remoteTouched ||
        beats(
          localTimes.strongestOf(group.where(localChanged.contains)),
          remoteTimes.strongestOf(group.where(remoteChanged.contains)),
        );
    if (remoteTouched) {
      conflicts.add(MergeConflict(group, keptLocal: takeLocal));
    }
    if (takeLocal) {
      for (final c in group) {
        if (!local.containsKey(c)) continue;
        merged[c] = local[c];
        final time = localTimes.of(c);
        if (time == null) {
          times.remove(c);
        } else if (!untimedColumns.contains(c)) {
          times[c] = time;
        }
      }
    }
  }
  return MergeResult(
    merged,
    conflicts,
    FieldTimes(times),
    sendsTimes: sendsTimes,
  );
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
///
/// A medication's stock is the server's: only `apply_stock_change` changes
/// it (a change waits in the stock outbox until then), and a pull brings
/// it. A push never sends it, so a rename cannot undo a dose taken on
/// another device (design section 4.8).
const medicationMerge = MergePolicy(
  groups: [
    {'barcode', 'ean'},
  ],
  serverOwned: {'quantity'},
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
    editedAt != null && FieldTime(editedAt).automatic;
