/// A fake Supabase server that behaves like the migrations up to
/// `20260918000000_sync_v2.sql`: one xid per request, a horizon held back
/// by transactions still open, `row_version`, the write-id rule, edit-time
/// normalisation, the edit times per column (`field_edited_at`), the
/// `updated_at` rules, guarded updates, the tombstone
/// cascade, hard deletes with their foreign-key cascade, the stock ledger
/// and an answer cap ([FakeServerCore.rowCap], 1000 by default; a real
/// project may be set lower).
///
/// The Dart-level fakes (`fake_remotes.dart`) and the HTTP fake
/// (`fake_postgrest.dart`) are both views of one [FakeServerCore], so the
/// server rules live in one place. Keep it in step with
/// `tools/sql/sync_v2_checks.sql`.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _weakCeiling = DateTime.utc(1970, 1, 2);
final _epoch = DateTime.utc(1970);

String _iso(DateTime t) => t.toUtc().toIso8601String();
DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

/// Columns with no edit time of their own (`c_untimed` in the trigger).
const _untimed = {
  'id',
  'user_id',
  'created_at',
  'updated_at',
  'deleted_at',
  'sync_xid',
  'row_version',
  'write_id',
  'edited_at',
  'field_edited_at',
  'quantity',
};

Map<String, Object?> _entry(DateTime at, bool auto) => {
  'at': _iso(at),
  'auto': auto,
};

final _zoned = RegExp(r'T.*(Z|[+-]\d\d:\d\d)$');

/// Equal as Postgres compares the stored values: a timestamp written as
/// `Z` equals the same instant written as `+00:00`.
bool _same(Object? a, Object? b) {
  if (a == b) return true;
  if (a is String && b is String && _zoned.hasMatch(a) && _zoned.hasMatch(b)) {
    return DateTime.parse(a).isAtSameMomentAs(DateTime.parse(b));
  }
  return false;
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        [
          for (var i = 0; i < a.length; i++) i,
        ].every((i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}

/// The children each parent's tombstone cascades to. A hard delete
/// cascades along the same foreign keys (`ON DELETE CASCADE`).
const _cascade = {
  'treatments': ('prescriptions', 'treatment_id'),
  'medications': ('prescriptions', 'medication_id'),
  'prescriptions': ('dose_logs', 'prescription_id'),
};

class FakeServerCore {
  FakeServerCore(this.clock);

  /// The server's `now()`.
  final DateTime Function() clock;

  int _nextXid = 1000;
  final Set<int> _open = {};

  /// Committed rows per table, by id.
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};

  /// The stock ledger: op id → what was applied (the values in range) and
  /// the quantity after it.
  final Map<
    String,
    ({String medicationId, int? delta, int? setTo, int quantityAfter})
  >
  ledger = {};

  /// Every request answered, in order (`table:verb`), for request counts.
  final List<String> requests = [];

  /// The most rows one fetch answers (PostgREST `max_rows`, the project's
  /// "Max rows" setting).
  int rowCap = 1000;

  Map<String, Map<String, dynamic>> rowsOf(String table) =>
      tables.putIfAbsent(table, () => {});

  /// `medora_sync_state()['horizon']`.
  int get horizon => _open.isEmpty ? _nextXid : _open.reduce(math.min);

  /// Starts a request that commits only when [FakeTransaction.commit] is
  /// called: its rows stay invisible and it holds the horizon back.
  FakeTransaction begin() {
    final xid = _nextXid++;
    _open.add(xid);
    return FakeTransaction._(this, xid);
  }

  T _request<T>(String what, T Function(int xid) body) {
    requests.add(what);
    return body(_nextXid++);
  }

  // ── The trigger ────────────────────────────────────────────

  Map<String, dynamic> _stamp(
    Map<String, dynamic>? old,
    Map<String, dynamic> row,
    int xid,
  ) {
    final now = clock().toUtc();
    row['sync_xid'] = xid;
    var edited = _time(row['edited_at']);
    var legacy = false;
    if (old == null) {
      row['row_version'] = 1;
      edited ??= _time(row['updated_at']) ?? now;
    } else {
      row['row_version'] = (old['row_version'] as int? ?? 1) + 1;
      final writeId = row['write_id'];
      if (writeId == null || writeId == old['write_id']) {
        legacy = true;
        row['write_id'] = null;
        edited = now;
      } else {
        edited ??= _time(old['updated_at']) ?? now;
      }
    }
    final weak = edited.isBefore(_weakCeiling);
    edited = weak ? _epoch : (edited.isAfter(now) ? now : edited);
    row['edited_at'] = _iso(edited);
    row['field_edited_at'] = _fieldTimes(old, row, legacy, edited, now);
    if (old == null) {
      if (!weak) {
        row['updated_at'] = _iso(now);
      } else if (!row.containsKey('updated_at')) {
        row['updated_at'] = _iso(now);
      }
    } else {
      row['updated_at'] = row['write_id'] != null && weak
          ? old['updated_at']
          : _iso(now);
    }
    return row;
  }

  /// The trigger's edit times per column: sent entries for the columns a
  /// write changes, capped at [now], automatic before 1970-01-02, never
  /// earlier than the entry held; a legacy write stamps its changes [now];
  /// an empty map is filled from the row's old time on the first update.
  Map<String, dynamic> _fieldTimes(
    Map<String, dynamic>? old,
    Map<String, dynamic> row,
    bool legacy,
    DateTime edited,
    DateTime now,
  ) {
    Object? sent;
    final map = <String, dynamic>{};
    if (old == null) {
      sent = row['field_edited_at'];
    } else {
      final held = old['field_edited_at'];
      if (!legacy && !_sameJson(row['field_edited_at'], held)) {
        sent = row['field_edited_at'];
      }
      if (held is Map && held.isNotEmpty) {
        map.addAll(Map<String, dynamic>.from(held));
      } else {
        var at = _time(old['edited_at']) ?? _time(old['updated_at']) ?? now;
        if (at.isAfter(now)) at = now;
        final auto = at.isBefore(_weakCeiling);
        for (final key in old.keys) {
          if (_untimed.contains(key)) continue;
          map[key] = _entry(auto ? _epoch : at, auto);
        }
      }
    }
    final entries = sent is Map ? sent : const <String, Object?>{};
    for (final key in row.keys) {
      if (_untimed.contains(key)) continue;
      final entry = entries[key];
      if (old == null) {
        if (entry == null) continue;
      } else if (_same(row[key], old[key])) {
        continue;
      }
      DateTime at;
      bool auto;
      if (legacy) {
        at = now;
        auto = false;
      } else {
        final e = entry is Map ? entry : const <String, Object?>{};
        at = _time(e['at']) ?? edited;
        auto = e['auto'] == true || at.isBefore(_weakCeiling);
      }
      at = auto ? _epoch : (at.isAfter(now) ? now : at);
      final heldAt = _time((map[key] as Map?)?['at']);
      if (heldAt != null && heldAt.isAfter(at)) at = heldAt;
      map[key] = _entry(at, auto);
    }
    return map;
  }

  // ── Requests ───────────────────────────────────────────────

  /// `insert … on conflict (id) do nothing`, one transaction.
  int insertIfAbsent(String table, List<Map<String, dynamic>> jsons) =>
      _request('$table:insert', (xid) => _insert(table, jsons, xid));

  int _insert(String table, List<Map<String, dynamic>> jsons, int xid) {
    final rows = rowsOf(table);
    var inserted = 0;
    for (final json in jsons) {
      final id = json['id'] as String;
      if (rows.containsKey(id)) continue;
      rows[id] = _stamp(null, {
        'created_at': _iso(clock()),
        'deleted_at': null,
        'write_id': null,
        ...json,
      }, xid);
      inserted++;
    }
    return inserted;
  }

  /// `update … where id = [id] [and row_version = ifVersion] [and status =
  /// ifStatus] [and deleted_at is null] returning *`.
  Map<String, dynamic>? patch(
    String table,
    String id,
    Map<String, dynamic> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => _request('$table:patch', (xid) {
    final old = rowsOf(table)[id];
    if (old == null) return null;
    if (ifVersion != null && old['row_version'] != ifVersion) return null;
    if (ifStatus != null && old['status'] != ifStatus) return null;
    if (ifLive && old['deleted_at'] != null) return null;
    return _update(table, old, changes, xid);
  });

  Map<String, dynamic> _update(
    String table,
    Map<String, dynamic> old,
    Map<String, dynamic> changes,
    int xid,
  ) {
    final id = old['id'] as String;
    final row = _stamp(old, {
      ...old,
      // A client that sends no write id leaves the column as it was; the
      // trigger then clears it.
      'write_id': old['write_id'],
      ...changes,
    }, xid);
    rowsOf(table)[id] = row;
    final child = _cascade[table];
    if (child != null &&
        old['deleted_at'] == null &&
        row['deleted_at'] != null) {
      for (final c in rowsOf(child.$1).values.toList()) {
        if (c[child.$2] == id && c['deleted_at'] == null) {
          _update(child.$1, c, {'deleted_at': row['deleted_at']}, xid);
        }
      }
    }
    return Map.of(row);
  }

  /// What Medora 0.3.0 sends: `upsert(toJson())`, no write id, no edit
  /// time; only the payload's columns are set on conflict.
  Map<String, dynamic> legacyUpsert(String table, Map<String, dynamic> json) =>
      _request('$table:legacy', (xid) {
        final old = rowsOf(table)[json['id']];
        if (old == null) {
          _insert(table, [json], xid);
          return Map.of(rowsOf(table)[json['id']]!);
        }
        return _update(table, old, {...json}..remove('write_id'), xid);
      });

  /// One page of a delta pull (`pullPage`).
  List<Map<String, dynamic>> page(
    String table, {
    required int horizon,
    int? afterXid,
    String? afterId,
    int limit = 1000,
  }) {
    requests.add('$table:page');
    final matching = [
      for (final r in rowsOf(table).values)
        if ((r['sync_xid'] as int) < horizon &&
            (afterXid == null ||
                (afterId == null
                    ? (r['sync_xid'] as int) >= afterXid
                    : _after(r, afterXid, afterId))))
          Map<String, dynamic>.of(r),
    ]..sort(_byKey);
    return matching.take(math.min(limit, rowCap)).toList();
  }

  static bool _after(Map<String, dynamic> r, int xid, String id) {
    final x = r['sync_xid'] as int;
    return x > xid || (x == xid && (r['id'] as String).compareTo(id) > 0);
  }

  static int _byKey(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byXid = (a['sync_xid'] as int).compareTo(b['sync_xid'] as int);
    return byXid != 0
        ? byXid
        : (a['id'] as String).compareTo(b['id'] as String);
  }

  Map<String, dynamic>? fetch(String table, String id) {
    requests.add('$table:fetch');
    final row = rowsOf(table)[id];
    return row == null ? null : Map.of(row);
  }

  /// `apply_stock_change(...)`. Like the server, an answer that writes
  /// nothing takes no transaction id.
  Map<String, dynamic> applyStockChange({
    required String opId,
    required String medicationId,
    int? delta,
    int? setTo,
  }) {
    requests.add('rpc:apply_stock_change');
    if ((delta == null) == (setTo == null)) {
      throw const PostgrestException(
        message: 'pass exactly one of p_delta and p_set_to',
        code: '22023',
      );
    }
    final inDelta = delta?.clamp(-999999, 999999);
    final inSetTo = setTo?.clamp(0, 999999);
    final done = ledger[opId];
    if (done != null) {
      return {'status': 'duplicate', 'quantity': done.quantityAfter};
    }
    final med = rowsOf('medications')[medicationId];
    if (med == null || med['deleted_at'] != null) return {'status': 'gone'};
    final current = (med['quantity'] as num?)?.toInt() ?? 0;
    final next = inSetTo ?? (current + inDelta!).clamp(0, 999999);
    final row = _update('medications', med, {
      'quantity': next,
      'write_id': opId,
    }, _nextXid++);
    ledger[opId] = (
      medicationId: medicationId,
      delta: inDelta,
      setTo: inSetTo,
      quantityAfter: next,
    );
    return {
      'status': 'applied',
      'quantity': next,
      'row_version': row['row_version'],
    };
  }

  /// `delete from [table] where id = [id]`: the row goes, its children go
  /// along the foreign keys, and a medication's ledger entries go with it.
  void purge(String table, String id) {
    requests.add('$table:delete');
    if (rowsOf(table).remove(id) == null) return;
    if (table == 'medications') {
      ledger.removeWhere((_, e) => e.medicationId == id);
    }
    for (final MapEntry(key: parent, value: (child, column))
        in _cascade.entries) {
      if (parent != table) continue;
      for (final c in rowsOf(child).values.toList()) {
        if (c[column] == id) purge(child, c['id'] as String);
      }
    }
  }

  /// `medora_sync_state()`.
  Map<String, dynamic> syncState() {
    requests.add('rpc:medora_sync_state');
    return {'schema': 2, 'horizon': horizon};
  }
}

/// A request whose transaction is still open ([FakeServerCore.begin]).
class FakeTransaction {
  FakeTransaction._(this._core, this.xid);

  final FakeServerCore _core;
  final int xid;
  final List<void Function()> _writes = [];

  /// A 0.3.0-style insert that lands when [commit] is called.
  void insert(String table, Map<String, dynamic> json) =>
      _writes.add(() => _core._insert(table, [json], xid));

  void commit() {
    for (final w in _writes) {
      w();
    }
    _core._open.remove(xid);
  }
}

/// [SyncTable] over [FakeServerCore], with the failure knobs the sync tests
/// use.
class FakeSyncTable implements SyncTable {
  FakeSyncTable(this.core, this.table);

  final FakeServerCore core;
  final String table;

  /// Ids whose writes throw, as a server that refuses them.
  final Set<String> failIds = {};

  /// Ids whose single-row fetch throws — a server that cannot be reached
  /// while the user is discarding a stuck row.
  final Set<String> failGetIds = {};

  /// When set, every page request throws it.
  Object? throwOnFetch;

  /// Awaited before every request; a test can hold a cycle open.
  Future<void> Function()? beforeCall;

  /// When set, a write to one of these ids lands but its answer is lost:
  /// the call throws after the server applied it.
  final Set<String> loseAnswerFor = {};

  /// Every page request: the key it asked from and the horizon.
  final List<({PullKey? after, int horizon})> pageCalls = [];

  /// The key of every page request, in order (null: from the start).
  List<PullKey?> get sinceCalls => [for (final c in pageCalls) c.after];

  /// Runs on every page request before it is answered ([call] counts from
  /// 1); a test can throw from it to fail one page.
  void Function(int call, PullKey? after)? onPage;

  /// The size of every insert request, in order.
  final List<int> insertBatches = [];

  Map<String, Map<String, dynamic>> get rows => core.rowsOf(table);

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  void _maybeLose(String id) {
    if (loseAnswerFor.remove(id)) {
      throw TimeoutException('answer lost for $table/$id');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) async {
    await beforeCall?.call();
    pageCalls.add((after: after, horizon: horizon));
    onPage?.call(pageCalls.length, after);
    final failure = throwOnFetch;
    if (failure != null) throw failure;
    return core.page(
      table,
      horizon: horizon,
      afterXid: after?.xid,
      afterId: after?.id,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetch(String id) async {
    await beforeCall?.call();
    if (failGetIds.contains(id)) {
      throw StateError('remote get failure for $id');
    }
    return core.fetch(table, id);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    await beforeCall?.call();
    return [for (final id in ids) ?core.fetch(table, id)];
  }

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    await beforeCall?.call();
    _guard(id);
    final written = core.patch(
      table,
      id,
      Map<String, dynamic>.of(changes),
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
    _maybeLose(id);
    return written;
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    await beforeCall?.call();
    for (final r in rows) {
      _guard(r['id']! as String);
    }
    insertBatches.add(rows.length);
    core.insertIfAbsent(table, [for (final r in rows) Map.of(r)]);
    for (final r in rows) {
      _maybeLose(r['id']! as String);
    }
  }

  // ── Test helpers ───────────────────────────────────────────

  /// Seeds a row as if a 0.3.0 device had written it before this test (no
  /// write id). [updatedAt] sets its `updated_at` and `edited_at`.
  Map<String, dynamic> seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    final row = core.legacyUpsert(table, json);
    if (updatedAt != null) {
      row['updated_at'] = _iso(updatedAt);
      row['edited_at'] = _iso(updatedAt);
      rows[row['id'] as String] = row;
    }
    return row;
  }

  /// Another 0.4.0 device's conditional-free update of [id].
  Map<String, dynamic>? editFromOtherDevice(
    String id,
    Map<String, dynamic> changes, {
    required DateTime editedAt,
    Map<String, Object?>? fieldTimes,
  }) => core.patch(table, id, {
    ...changes,
    'write_id': 'other-${core.requests.length}',
    'edited_at': _iso(editedAt),
    'field_edited_at': ?fieldTimes,
  });

  Map<String, dynamic>? get(String id) => rows[id];
}

/// [StockRemote] over [FakeServerCore].
class FakeStockRemote implements StockRemote {
  FakeStockRemote(this.core);

  final FakeServerCore core;

  /// How many of the next changes land with their answer lost.
  int loseNextAnswers = 0;

  @override
  Future<StockChangeResult> apply(StockOp op) async {
    final json = core.applyStockChange(
      opId: op.opId,
      medicationId: op.medicationId,
      delta: op.delta,
      setTo: op.setTo,
    );
    if (loseNextAnswers > 0) {
      loseNextAnswers--;
      throw TimeoutException('answer lost for stock change ${op.opId}');
    }
    return StockChangeResult.fromJson(json);
  }
}

extension FakeSyncTableLegacy on FakeSyncTable {
  /// A 0.3.0 device's whole-row upsert; returns the stored `updated_at`.
  Future<DateTime?> upsert(Map<String, dynamic> json) async {
    final row = core.legacyUpsert(table, json);
    return DateTime.tryParse(row['updated_at'] as String? ?? '')?.toUtc();
  }

  /// A 0.3.0 device's delete.
  void tombstone(String id) {
    if (rows[id] == null) return;
    core.patch(table, id, {'deleted_at': _iso(core.clock())});
  }

  /// A row removed from the server (a purge, or "delete all data"), with
  /// what the foreign keys cascade to ([FakeServerCore.purge]).
  void hardDelete(String id) => core.purge(table, id);

  List<Map<String, dynamic>> all() => rows.values.map(Map.of).toList();

  List<Map<String, dynamic>> live() =>
      all().where((r) => r['deleted_at'] == null).toList();

  DateTime? updatedAt(String id) =>
      DateTime.tryParse(rows[id]?['updated_at'] as String? ?? '')?.toUtc();
}
