/// Medora - One page of a delta pull.
///
/// A hosted Supabase project answers at most 1000 rows per request (the
/// PostgREST `max_rows` setting) and says nothing when it cut an answer
/// short. A delta pull therefore asks for its rows in pages, in a stable
/// order: `updated_at` ascending, then `id` ascending as the tiebreak, so
/// rows that share one `updated_at` (every dose the app generated carries
/// the same 1970 stamp) are neither skipped nor repeated across pages.
///
/// Each page after the first starts strictly after the last row of the page
/// before it (keyset paging, [PullKey]). Unlike an offset, a key does not
/// shift when another device changes a row while the pull runs: a changed
/// row only moves to the end of the order, where a later page or the next
/// cycle finds it.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// The most rows one pull request asks for. At the default PostgREST cap, so
/// a page shorter than this is the last one.
const pullPageSize = 1000;

/// The position of a row in the pull order: its `updated_at`, then its id.
class PullKey {
  const PullKey(this.updatedAt, this.id);

  final DateTime updatedAt;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is PullKey && other.updatedAt == updatedAt && other.id == id;

  @override
  int get hashCode => Object.hash(updatedAt, id);

  @override
  String toString() => 'PullKey(${updatedAt.toIso8601String()}, $id)';
}

/// [query] narrowed to one page of a delta pull: rows changed after [since]
/// (all rows when null) that come after [after] in the pull order (from the
/// start when null), in that order, at most [limit] of them.
PostgrestTransformBuilder<PostgrestList> pullPage(
  PostgrestFilterBuilder<PostgrestList> query, {
  required DateTime? since,
  required PullKey? after,
  int limit = pullPageSize,
}) {
  var filtered = query;
  if (since != null) {
    filtered = filtered.gt('updated_at', since.toUtc().toIso8601String());
  }
  if (after != null) {
    final stamp = _quoted(after.updatedAt.toUtc().toIso8601String());
    final id = _quoted(after.id);
    filtered = filtered.or(
      'updated_at.gt.$stamp,and(updated_at.eq.$stamp,id.gt.$id)',
    );
  }
  return filtered
      .order('updated_at', ascending: true)
      .order('id', ascending: true)
      .limit(limit);
}

/// [value] as a double-quoted PostgREST filter value, so the dots, colons,
/// commas and parentheses it may hold are not read as syntax.
String _quoted(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
