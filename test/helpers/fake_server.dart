/// A fake Supabase server that behaves like the migrations up to
/// `20260918000000_sync_v2.sql`: one xid per request, a horizon held back
/// by transactions still open, `row_version`, the write-id rule, edit-time
/// normalisation, the `updated_at` rules, guarded updates, the tombstone
/// cascade, the stock ledger and a 1000-row answer cap.
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

final _weakCeiling = DateTime.utc(1970, 1, 2);
final _epoch = DateTime.utc(1970);

String _iso(DateTime t) => t.toUtc().toIso8601String();
DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

/// The children each parent's tombstone cascades to.
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

  /// The stock ledger: op id → the quantity after it was applied.
  final Map<String, ({String medicationId, int quantityAfter})> ledger = {};

  /// Every request answered, in order (`table:verb`), for request counts.
  final List<String> requests = [];

  /// The most rows one fetch answers (PostgREST `max_rows`).
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
    if (old == null) {
      row['row_version'] = 1;
      edited ??= _time(row['updated_at']) ?? now;
    } else {
      row['row_version'] = (old['row_version'] as int? ?? 1) + 1;
      final writeId = row['write_id'];
      if (writeId == null || writeId == old['write_id']) {
        row['write_id'] = null;
        edited = now;
      } else {
        edited ??= _time(old['updated_at']) ?? now;
      }
    }
    final weak = edited.isBefore(_weakCeiling);
    edited = weak ? _epoch : (edited.isAfter(now) ? now : edited);
    row['edited_at'] = _iso(edited);
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

  /// `apply_stock_change(...)`.
  Map<String, dynamic> applyStockChange({
    required String opId,
    required String medicationId,
    int? delta,
    int? setTo,
  }) => _request('rpc:apply_stock_change', (xid) {
    if ((delta == null) == (setTo == null)) {
      throw ArgumentError('pass exactly one of delta and setTo');
    }
    final done = ledger[opId];
    if (done != null) {
      return {'status': 'duplicate', 'quantity': done.quantityAfter};
    }
    final med = rowsOf('medications')[medicationId];
    if (med == null) return {'status': 'missing'};
    if (med['deleted_at'] != null) return {'status': 'gone'};
    final current = (med['quantity'] as num?)?.toInt() ?? 0;
    final next = (setTo ?? current + delta!).clamp(0, 999999);
    final row = _update('medications', med, {
      'quantity': next,
      'write_id': opId,
    }, xid);
    ledger[opId] = (medicationId: medicationId, quantityAfter: next);
    return {
      'status': 'applied',
      'quantity': next,
      'row_version': row['row_version'],
    };
  });

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
  }) => core.patch(table, id, {
    ...changes,
    'write_id': 'other-${core.requests.length}',
    'edited_at': _iso(editedAt),
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

  /// A row removed by a server purge.
  void hardDelete(String id) => rows.remove(id);

  List<Map<String, dynamic>> all() => rows.values.map(Map.of).toList();

  List<Map<String, dynamic>> live() =>
      all().where((r) => r['deleted_at'] == null).toList();

  DateTime? updatedAt(String id) =>
      DateTime.tryParse(rows[id]?['updated_at'] as String? ?? '')?.toUtc();
}
