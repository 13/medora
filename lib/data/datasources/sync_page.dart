/// Medora - One page of a delta pull (sync v2).
///
/// Every synced row carries `sync_xid`, the id of the transaction that last
/// wrote it (migration 20260918000000). A pull asks the server for its
/// horizon first (`medora_sync_state`): every transaction below it has
/// finished, so every row with `sync_xid < horizon` that will ever be
/// visible is visible now. A pull then reads `[its key, horizon)` in pages,
/// ordered by `sync_xid` and then `id`, and a row committed late is never
/// skipped: its transaction id keeps it above the horizon until it commits.
///
/// A project answers at most its "Max rows" setting per request (1000 on a
/// new hosted project, but the owner may lower it) and says nothing when it
/// cut an answer short. So a page shorter than [pullPageSize] is not the
/// last one: only an empty page ends a table ([afterPullPage]). That costs
/// one more request per table per pull. The horizon cannot end a table
/// earlier either: rows of one transaction share a `sync_xid`, so a page
/// that ends at `horizon - 1` may still have rows after it.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// The most rows one pull request asks for.
const pullPageSize = 1000;

/// Where a pull continues: after the row `(xid, id)`, or, with no [id],
/// from the first row whose `sync_xid` is at least [xid].
class PullKey {
  const PullKey(this.xid, [this.id]);

  /// Parses [toStorage]'s output; null for anything else.
  static PullKey? fromStorage(String? raw) {
    if (raw == null) return null;
    final bar = raw.indexOf('|');
    if (bar < 0) return null;
    final xid = int.tryParse(raw.substring(0, bar));
    if (xid == null) return null;
    final id = raw.substring(bar + 1);
    return PullKey(xid, id.isEmpty ? null : id);
  }

  final int xid;
  final String? id;

  String toStorage() => '$xid|${id ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is PullKey && other.xid == xid && other.id == id;

  @override
  int get hashCode => Object.hash(xid, id);

  @override
  String toString() => 'PullKey($xid, $id)';
}

/// [query] narrowed to one page: rows below [horizon] that come after
/// [after] (from the start when null), in `sync_xid, id` order, at most
/// [limit] of them.
PostgrestTransformBuilder<PostgrestList> pullPage(
  PostgrestFilterBuilder<PostgrestList> query, {
  required PullKey? after,
  required int horizon,
  int limit = pullPageSize,
}) {
  var filtered = query.lt('sync_xid', horizon);
  if (after != null) {
    final id = after.id;
    filtered = id == null
        ? filtered.gte('sync_xid', after.xid)
        : filtered.or(
            'sync_xid.gt.${after.xid},'
            'and(sync_xid.eq.${after.xid},id.gt.${_quoted(id)})',
          );
  }
  return filtered
      .order('sync_xid', ascending: true)
      .order('id', ascending: true)
      .limit(limit);
}

/// [value] as a double-quoted PostgREST filter value, so the dots, colons,
/// commas and parentheses it may hold are not read as syntax.
String _quoted(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Where a pull goes after it applied [rows], one page asked with
/// [horizon]: the key to store, and whether the table is done.
///
/// Only an empty page is the end; its key is `PullKey(horizon)`, so the
/// next pull starts at the first row a later transaction writes. Any other
/// page, however short, continues after its last row.
({PullKey key, bool done}) afterPullPage(
  List<Map<String, dynamic>> rows, {
  required int horizon,
}) {
  if (rows.isEmpty) return (key: PullKey(horizon), done: true);
  final last = rows.last;
  return (
    key: PullKey((last['sync_xid']! as num).toInt(), last['id']! as String),
    done: false,
  );
}
