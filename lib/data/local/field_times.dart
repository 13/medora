/// Medora - When each column of a synced row was last changed
/// (`field_edited_at`, sync v2).
///
/// The row's `edited_at` says when its last change was made. That is not
/// enough to merge: a row can carry an older change to one column after a
/// newer change to another. So every synced row also keeps a map, column
/// name to [FieldTime], and the merge compares the times of the column it
/// decides on.
///
/// The server keeps the same map (`supabase/migrations/
/// 20260918000000_sync_v2.sql`) with the same meaning:
/// - an entry is the time of the column's last applied change, UTC, and
///   whether the app made that change on its own ([FieldTime.automatic]);
/// - an **empty** map means no column changed since the row was written:
///   every column carries the row's own time ([FieldTimes.rowTime]);
/// - a column missing from a filled map has an unknown time, which loses to
///   any person's change;
/// - the stock and the bookkeeping columns ([untimedColumns]) have none.
library;

import 'dart:convert';

/// Edit times before this mark a change the app made on its own.
final DateTime automaticCeiling = DateTime.utc(1970, 1, 2);

/// Keys that are bookkeeping on every synced table: never merged, diffed or
/// timed.
const bookkeepingColumns = {
  'id',
  'user_id',
  'created_at',
  'updated_at',
  'deleted_at',
};

/// Columns with no edit time of their own: the bookkeeping, and the stock,
/// which only the server's stock function writes.
const untimedColumns = {...bookkeepingColumns, 'quantity'};

/// When one column was last changed, and whether a person changed it.
class FieldTime {
  const FieldTime._(this.at, this.automatic);

  /// A change made at [at]; a time before [automaticCeiling] is a change
  /// the app made on its own.
  factory FieldTime(DateTime at) => at.toUtc().isBefore(automaticCeiling)
      ? automaticChange
      : FieldTime._(at.toUtc(), false);

  /// A change the app made on its own.
  static final FieldTime automaticChange = FieldTime._(
    DateTime.utc(1970),
    true,
  );

  /// An entry as the server or a local row stores it; null when it does not
  /// parse. The server can keep a real time on an automatic entry (a time
  /// never goes back there); the flag is what counts.
  static FieldTime? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['at'];
    final at = text is String ? DateTime.tryParse(text) : null;
    if (at == null) return null;
    return raw['auto'] == true ? FieldTime._(at.toUtc(), true) : FieldTime(at);
  }

  /// The time, UTC.
  final DateTime at;
  final bool automatic;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'auto': automatic,
  };

  @override
  bool operator ==(Object other) =>
      other is FieldTime && other.at == at && other.automatic == automatic;

  @override
  int get hashCode => Object.hash(at, automatic);

  @override
  String toString() =>
      'FieldTime(${at.toIso8601String()}${automatic ? ', automatic' : ''})';
}

/// True when a change timed [a] beats a change timed [b] to the same
/// column: a person's change beats an unknown time (null), which beats an
/// automatic change; two people's changes go by time, compared as instants.
/// A tie, and two automatic changes, keep [b].
bool beats(FieldTime? a, FieldTime? b) {
  if (a == null) return b != null && b.automatic;
  if (a.automatic) return false;
  if (b == null || b.automatic) return true;
  return a.at.isAfter(b.at);
}

/// The edit times of one copy of a row.
class FieldTimes {
  FieldTimes(Map<String, FieldTime> entries, {this.rowTime})
    : entries = Map.unmodifiable(entries);

  /// The map as a local row (JSON text) or the server (a JSON object)
  /// stores it; [rowTime] is the row's own time (see [of]). Anything that
  /// is not a map reads as an empty one, and an entry that does not parse
  /// is left out.
  factory FieldTimes.decode(Object? raw, {DateTime? rowTime}) {
    var value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        value = null;
      }
    }
    final entries = <String, FieldTime>{};
    if (value is Map) {
      for (final MapEntry(:key, value: entry) in value.entries) {
        final time = FieldTime.fromJson(entry);
        if (key is String && time != null) entries[key] = time;
      }
    }
    return FieldTimes(entries, rowTime: rowTime);
  }

  final Map<String, FieldTime> entries;

  /// When the row itself was last changed (`edited_at`, else `updated_at`):
  /// the time of every column while [entries] is empty.
  final DateTime? rowTime;

  /// The time of [column]'s last change; null when it is unknown.
  FieldTime? of(String column) {
    final entry = entries[column];
    if (entry != null) return entry;
    final row = rowTime;
    return entries.isEmpty && row != null ? FieldTime(row) : null;
  }

  /// The change among [columns] that beats the others ([beats]); null when
  /// there is none, or the strongest has an unknown time.
  FieldTime? strongestOf(Iterable<String> columns) {
    var first = true;
    FieldTime? best;
    for (final column in columns) {
      final time = of(column);
      if (first || beats(time, best)) best = time;
      first = false;
    }
    return best;
  }

  /// The known time of each of [columns], as a filled map.
  Map<String, FieldTime> resolved(Iterable<String> columns) => {
    for (final column in columns)
      if (!untimedColumns.contains(column) && of(column) != null)
        column: of(column)!,
  };

  /// The map after a write, made at [at], that changed [changed] of the
  /// row's [columns]. An empty map is filled from [rowTime] first, because
  /// the write moves the row's own time.
  FieldTimes stamped({
    required Iterable<String> columns,
    required Iterable<String> changed,
    required DateTime at,
  }) {
    final next = entries.isEmpty ? resolved(columns) : {...entries};
    for (final column in changed) {
      if (!untimedColumns.contains(column)) next[column] = FieldTime(at);
    }
    return FieldTimes(next, rowTime: rowTime);
  }

  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in entries.entries) key: value.toJson(),
  };

  /// The local column's text; null for an empty map.
  String? encode() => entries.isEmpty ? null : jsonEncode(toJson());
}

/// The columns of the wire copy [after] whose value differs from [before],
/// [untimedColumns] left out. With no [before], every column counts.
Set<String> timedChanges(
  Map<String, Object?>? before,
  Map<String, Object?> after,
) => {
  for (final MapEntry(:key, :value) in after.entries)
    if (!untimedColumns.contains(key) &&
        (before == null || !before.containsKey(key) || before[key] != value))
      key,
};

/// The time of the local row [row]: its `edited_at`, or its `updated_at`
/// (naive local text from 0.3.0 reads as an instant in this zone).
DateTime? localRowTime(Map<String, Object?> row) {
  for (final column in ['edited_at', 'updated_at']) {
    final raw = row[column];
    final time = raw is String ? DateTime.tryParse(raw) : null;
    if (time != null) return time.toUtc();
  }
  return null;
}

/// The `field_edited_at` text a local write stores, made at [at], that
/// turns the stored row [previous] into [after]. [wireOf] gives a row's
/// wire copy, so a value written in another format is no change. A new row
/// ([previous] null) stores none: its `edited_at` stands for every column.
String? fieldTimesAfterWrite({
  required Map<String, Object?>? previous,
  required Map<String, Object?> after,
  required Map<String, Object?> Function(Map<String, Object?> row) wireOf,
  required DateTime at,
}) {
  if (previous == null) return null;
  final before = wireOf(previous);
  final next = wireOf(after);
  return FieldTimes.decode(
        previous['field_edited_at'],
        rowTime: localRowTime(previous),
      )
      .stamped(columns: next.keys, changed: timedChanges(before, next), at: at)
      .encode();
}
