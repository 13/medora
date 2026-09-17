/// A fake Supabase server that behaves like the migrations up to
/// `20260918000000_sync_v2.sql`: one xid per request, a horizon held back
/// by transactions still open, `row_version`, the write-id rule, edit-time
/// normalisation, the edit times per column (`field_edited_at`), the
/// `updated_at` rules, guarded updates, the tombstone cascade and the
/// children of deleted parents (stored deleted), a 0.3.0 take bringing
/// back a dose the app deleted, hard deletes with their foreign-key
/// cascade, the stock ledger
/// and an answer cap ([FakeServerCore.rowCap], 1000 by default; a real
/// project may be set lower).
///
/// Rows hold every column of their table ([serverColumns]), with its
/// default, as Postgres rows do; a write naming any other column is refused
/// (PGRST204). Foreign keys are not checked.
///
/// The Dart-level fakes (`fake_remotes.dart`) are views of one
/// [FakeServerCore], so the server rules live in one place. Keep it in step
/// with `tools/sql/sync_v2_checks.sql`; `fake_server_parity_test.dart`
/// checks the same writes against the migration itself.
///
/// Every fake table and stock remote reaches the core one of two ways
/// ([FakeTransport]): straight, or through the app's real PostgREST
/// datasources and [FakePostgrest]. The failure knobs work the same either
/// way. `--dart-define=MEDORA_FAKE_TRANSPORT=http` switches the default, so
/// the whole suite can run over HTTP.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_postgrest.dart';

/// How a fake table reaches [FakeServerCore].
enum FakeTransport {
  /// Method calls on the core.
  dart,

  /// The app's PostgREST datasources, answered by [FakePostgrest].
  http,
}

/// The transport a fake uses unless a test names one.
const FakeTransport defaultFakeTransport =
    String.fromEnvironment('MEDORA_FAKE_TRANSPORT') == 'http'
    ? FakeTransport.http
    : FakeTransport.dart;

final _weakCeiling = DateTime.utc(1970, 1, 2);
final _epoch = DateTime.utc(1970);

String _iso(DateTime t) => t.toUtc().toIso8601String();
DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

/// Columns with no edit time of their own (`c_untimed` in the trigger).
const serverUntimedColumns = {
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

/// The sync bookkeeping `20260918000000_sync_v2.sql` adds to every table,
/// with its defaults.
const _syncColumns = <String, Object?>{
  'sync_xid': 0,
  'row_version': 1,
  'write_id': null,
  'edited_at': null,
  'field_edited_at': <String, Object?>{},
};

/// `now()`: a default the insert fills with the server's clock.
const _nowDefault = #now;

/// Every column of the four synced tables after all migrations, with its
/// default (null when it has none). An inserted row holds all of them, as a
/// Postgres row does, so the trigger's fill (which reads every column of
/// the old row) and PostgREST's answers match the real server.
const serverColumns = <String, Map<String, Object?>>{
  'medications': {
    'id': null,
    'user_id': null,
    'family_id': null,
    'name': null,
    'description': null,
    'active_ingredients': null,
    'category': null,
    'manufacturer': null,
    'form': null,
    'atc_code': null,
    'symptoms': null,
    'patient_tags': null,
    'purchase_date': null,
    'expiry_date': null,
    'quantity': 0,
    'quantity_unit': null,
    'minimum_stock_level': 0,
    'storage_location': null,
    'barcode': null,
    'image_path': null,
    'notes': null,
    'is_archived': false,
    'created_at': _nowDefault,
    'updated_at': _nowDefault,
    'deleted_at': null,
    'ean': null,
    ..._syncColumns,
  },
  'treatments': {
    'id': null,
    'user_id': null,
    'family_id': null,
    'name': null,
    'patient_tags': null,
    'symptom_tags': null,
    'start_date': null,
    'end_date': null,
    'is_active': true,
    'notes': null,
    'created_at': _nowDefault,
    'updated_at': _nowDefault,
    'deleted_at': null,
    'sick_leave_from': null,
    'sick_leave_to': null,
    'sick_leave_ref': null,
    'doctor': null,
    ..._syncColumns,
  },
  'prescriptions': {
    'id': null,
    'treatment_id': null,
    'medication_id': null,
    'dosage': null,
    'dosage_amount': null,
    'dosage_unit': null,
    'interval_hours': 8,
    'duration_days': 7,
    'start_time': null,
    'is_active': true,
    'auto_diminish': false,
    'notes': null,
    'schedule_type': 'fixed_interval',
    'schedule_times': null,
    'created_at': _nowDefault,
    'updated_at': _nowDefault,
    'deleted_at': null,
    ..._syncColumns,
  },
  'dose_logs': {
    'id': null,
    'prescription_id': null,
    'scheduled_time': null,
    'taken_time': null,
    'status': 'pending',
    'notes': null,
    'created_at': _nowDefault,
    'updated_at': _nowDefault,
    'deleted_at': null,
    ..._syncColumns,
  },
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

  /// The account's "delete all data" marker (`sync_wipes`); the fake
  /// serves one account.
  ({int generation, DateTime wipedAt})? wipe;

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

  /// `medora_sync_stamp()` and `update_updated_at()` for a write of [row]
  /// over [old] (null: an insert). [cascade] marks the tombstone cascade, a
  /// write another trigger makes.
  Map<String, dynamic> _stamp(
    String table,
    Map<String, dynamic>? old,
    Map<String, dynamic> row,
    int xid, {
    bool cascade = false,
  }) {
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
    // An insert from a device that has not seen the last wipe, of a row a
    // person changed before it, lands deleted as that person's delete.
    final sentMap = row['field_edited_at'];
    final seen = sentMap is Map ? sentMap['@wipe'] : null;
    final lastWipe = wipe;
    final wipeDelete =
        old == null &&
        row['deleted_at'] == null &&
        row['write_id'] != null &&
        seen is int &&
        !weak &&
        lastWipe != null &&
        lastWipe.generation > seen &&
        !edited.isAfter(lastWipe.wipedAt);
    if (wipeDelete) row['deleted_at'] = _iso(lastWipe.wipedAt);
    // The row stays or becomes the app's own tombstone.
    var appDelete = false;
    if (old != null &&
        legacy &&
        !cascade &&
        old['deleted_at'] != null &&
        (_time(old['edited_at'])?.isBefore(_weakCeiling) ?? false) &&
        _same(row['deleted_at'], old['deleted_at'])) {
      // A 0.3.0 take of a dose the app deleted brings it back.
      if (table == 'dose_logs' &&
          const {'taken', 'skipped'}.contains(row['status']) &&
          !_same(row['status'], old['status'])) {
        row['deleted_at'] = null;
      } else {
        appDelete = true;
      }
    }
    row['edited_at'] = _iso(edited);
    row['field_edited_at'] = _fieldTimes(old, row, legacy, edited, now);
    if (old == null && !weak) row['updated_at'] = _iso(now);
    // A live child under a deleted parent is stored deleted.
    if (row['deleted_at'] == null) {
      final parentDeleted = _parentDeleted(table, row);
      if (parentDeleted != null) {
        row['deleted_at'] = parentDeleted;
        appDelete = true;
      }
    }
    if (cascade || appDelete) {
      row['edited_at'] = _iso(_epoch);
    } else if (wipeDelete) {
      row['edited_at'] = _iso(lastWipe.wipedAt);
    }
    if (old != null) {
      final automatic =
          row['write_id'] != null && row['edited_at'] == _iso(_epoch);
      row['updated_at'] = automatic ? old['updated_at'] : _iso(now);
    }
    return row;
  }

  /// The `deleted_at` of a deleted parent of [row], a row of [table]; null
  /// when every parent it names is live or not here.
  Object? _parentDeleted(String table, Map<String, dynamic> row) {
    Object? deletedAt(String parent, Object? id) =>
        rowsOf(parent)[id]?['deleted_at'];
    return switch (table) {
      'prescriptions' =>
        deletedAt('treatments', row['treatment_id']) ??
            deletedAt('medications', row['medication_id']),
      'dose_logs' => deletedAt('prescriptions', row['prescription_id']),
      _ => null,
    };
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
          if (serverUntimedColumns.contains(key)) continue;
          map[key] = _entry(auto ? _epoch : at, auto);
        }
      }
    }
    final entries = sent is Map ? sent : const <String, Object?>{};
    for (final key in row.keys) {
      if (serverUntimedColumns.contains(key)) continue;
      final entry = entries[key];
      if (old == null) {
        if (entry == null) continue;
      } else if (_same(row[key], old[key])) {
        // An unchanged value: only a person's time sent for it, later than
        // the one held, moves its entry (the same value set again later).
        if (entry is! Map || entry['auto'] == true) continue;
        final sentAt = _time(entry['at']);
        if (sentAt == null || sentAt.isBefore(_weakCeiling)) continue;
        final capped = sentAt.isAfter(now) ? now : sentAt;
        final heldAt = _time((map[key] as Map?)?['at']);
        if (heldAt != null && !capped.isAfter(heldAt)) continue;
      }
      // A changed column with no entry takes the time the write carried (a
      // legacy write: its arrival).
      final e = entry is Map ? entry : const <String, Object?>{};
      var at = _time(e['at']) ?? edited;
      final auto = e['auto'] == true || at.isBefore(_weakCeiling);
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
    for (final json in jsons) {
      _knownColumns(table, json.keys);
    }
    var inserted = 0;
    for (final json in jsons) {
      final id = json['id'] as String;
      if (rows.containsKey(id)) continue;
      rows[id] = _stamp(table, null, {..._defaults(table, json), ...json}, xid);
      inserted++;
    }
    return inserted;
  }

  /// PostgREST refuses a write that names a column the table does not have
  /// (PGRST204), before anything is written.
  static void _knownColumns(String table, Iterable<String> keys) {
    final columns = serverColumns[table];
    if (columns == null) return;
    for (final key in keys) {
      if (!columns.containsKey(key)) {
        throw PostgrestException(
          message:
              "Could not find the '$key' column of '$table' in the schema "
              'cache',
          code: 'PGRST204',
        );
      }
    }
  }

  /// The columns [json] leaves out, with the table's defaults. A table the
  /// fake does not know gets the bookkeeping only.
  Map<String, dynamic> _defaults(String table, Map<String, dynamic> json) {
    final columns =
        serverColumns[table] ??
        const {
          'created_at': _nowDefault,
          'updated_at': _nowDefault,
          'deleted_at': null,
          'write_id': null,
        };
    final now = _iso(clock());
    return {
      for (final MapEntry(:key, :value) in columns.entries)
        if (!json.containsKey(key))
          key: switch (value) {
            _nowDefault => now,
            final Map<String, Object?> map => Map<String, dynamic>.of(map),
            _ => value,
          },
    };
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
    _knownColumns(table, changes.keys);
    final old = rowsOf(table)[id];
    if (old == null) return null;
    if (ifVersion != null && old['row_version'] != ifVersion) return null;
    if (ifStatus != null && old['status'] != ifStatus) return null;
    if (ifLive && old['deleted_at'] != null) return null;
    return _update(table, old, changes, xid);
  });

  /// `update … where id in ([ids]) [and row_version = ifVersion] [and
  /// status = ifStatus] [and deleted_at is null] returning *`: one
  /// statement, one transaction.
  List<Map<String, dynamic>> patchMany(
    String table,
    List<String> ids,
    Map<String, dynamic> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => _request('$table:patchMany', (xid) {
    _knownColumns(table, changes.keys);
    final written = <Map<String, dynamic>>[];
    for (final id in ids) {
      final old = rowsOf(table)[id];
      if (old == null) continue;
      if (ifVersion != null && old['row_version'] != ifVersion) continue;
      if (ifStatus != null && old['status'] != ifStatus) continue;
      if (ifLive && old['deleted_at'] != null) continue;
      written.add(_update(table, old, Map.of(changes), xid));
    }
    return written;
  });

  Map<String, dynamic> _update(
    String table,
    Map<String, dynamic> old,
    Map<String, dynamic> changes,
    int xid, {
    bool cascade = false,
  }) {
    final id = old['id'] as String;
    final row = _stamp(
      table,
      old,
      {
        ...old,
        // A client that sends no write id leaves the column as it was; the
        // trigger then clears it.
        'write_id': old['write_id'],
        ...changes,
      },
      xid,
      cascade: cascade,
    );
    rowsOf(table)[id] = row;
    final child = _cascade[table];
    if (child != null &&
        old['deleted_at'] == null &&
        row['deleted_at'] != null) {
      for (final c in rowsOf(child.$1).values.toList()) {
        if (c[child.$2] == id && c['deleted_at'] == null) {
          _update(
            child.$1,
            c,
            {'deleted_at': row['deleted_at']},
            xid,
            cascade: true,
          );
        }
      }
    }
    return Map.of(row);
  }

  /// What Medora 0.3.0 sends: `upsert(toJson())`, no write id, no edit
  /// time; only the payload's columns are set on conflict.
  Map<String, dynamic> legacyUpsert(String table, Map<String, dynamic> json) =>
      _request('$table:legacy', (xid) {
        _knownColumns(table, json.keys);
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

  /// `select … where id in ([ids])`: one request.
  List<Map<String, dynamic>> fetchMany(String table, List<String> ids) {
    requests.add('$table:fetchMany');
    return [
      for (final id in ids)
        if (rowsOf(table)[id] case final row?) Map.of(row),
    ];
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
    final last = wipe;
    return {
      'schema': 2,
      'horizon': horizon,
      'wipe': last == null
          ? null
          : {'generation': last.generation, 'wiped_at': _iso(last.wipedAt)},
    };
  }

  /// `medora_delete_all_data()`: every medication, treatment, prescription
  /// and dose goes (with the ledger), and the marker moves on, at the
  /// server's clock.
  Map<String, dynamic> deleteAllData() {
    requests.add('rpc:medora_delete_all_data');
    final mark = requests.length;
    final at = clock().toUtc();
    wipe = (generation: (wipe?.generation ?? 0) + 1, wipedAt: at);
    for (final table in const [
      'dose_logs',
      'prescriptions',
      'treatments',
      'medications',
    ]) {
      for (final id in rowsOf(table).keys.toList()) {
        purge(table, id);
      }
    }
    // One request: the deletes inside it are not requests of their own.
    requests.removeRange(mark, requests.length);
    return {'generation': wipe!.generation, 'wiped_at': _iso(at)};
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
  FakeSyncTable(this.core, this.table, {FakeTransport? transport})
    : wire = (transport ?? defaultFakeTransport) == FakeTransport.http
          ? FakePostgrest.of(core).table(table)
          : null;

  final FakeServerCore core;
  final String table;

  /// The real PostgREST table the requests go through, in
  /// [FakeTransport.http]; null when they go straight to [core].
  final SyncTable? wire;

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

  /// Every row a write sent, in order: a patch's changes, or one inserted
  /// row.
  final List<Map<String, Object?>> sent = [];

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
    final http = wire;
    if (http != null) return http.page(after: after, horizon: horizon);
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
    final http = wire;
    return http != null ? http.fetch(id) : core.fetch(table, id);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    await beforeCall?.call();
    for (final id in ids) {
      if (failGetIds.contains(id)) {
        throw StateError('remote get failure for $id');
      }
    }
    final http = wire;
    return http != null ? http.fetchMany(ids) : core.fetchMany(table, ids);
  }

  /// Every bulk write: its ids and the conditions it carried.
  final List<({List<String> ids, int? ifVersion, String? ifStatus})>
  patchManyCalls = [];

  @override
  Future<List<Map<String, dynamic>>> patchMany(
    List<String> ids,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    await beforeCall?.call();
    ids.forEach(_guard);
    patchManyCalls.add((ids: ids, ifVersion: ifVersion, ifStatus: ifStatus));
    for (final _ in ids) {
      sent.add(Map.of(changes));
    }
    final http = wire;
    final written = http != null
        ? await http.patchMany(
            ids,
            changes,
            ifVersion: ifVersion,
            ifStatus: ifStatus,
            ifLive: ifLive,
          )
        : core.patchMany(
            table,
            ids,
            Map<String, dynamic>.of(changes),
            ifVersion: ifVersion,
            ifStatus: ifStatus,
            ifLive: ifLive,
          );
    ids.forEach(_maybeLose);
    return written;
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
    sent.add(Map.of(changes));
    final http = wire;
    final written = http != null
        ? await http.patch(
            id,
            changes,
            ifVersion: ifVersion,
            ifStatus: ifStatus,
            ifLive: ifLive,
          )
        : core.patch(
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
    // One insert statement names one column list (PostgREST).
    final keys = rows.isEmpty ? const <String>{} : rows.first.keys.toSet();
    for (final r in rows) {
      if (r.keys.toSet().length != keys.length || !keys.containsAll(r.keys)) {
        throw ArgumentError('the rows of one insert have different keys');
      }
    }
    insertBatches.add(rows.length);
    sent.addAll(rows.map(Map.of));
    final http = wire;
    if (http != null) {
      await http.insertIfAbsent(rows);
    } else {
      core.insertIfAbsent(table, [for (final r in rows) Map.of(r)]);
    }
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
  FakeStockRemote(this.core, {FakeTransport? transport})
    : wire = (transport ?? defaultFakeTransport) == FakeTransport.http
          ? FakePostgrest.of(core).stock()
          : null;

  final FakeServerCore core;

  /// `PostgrestStockRemote` over [FakePostgrest], in [FakeTransport.http].
  final StockRemote? wire;

  /// How many of the next changes land with their answer lost.
  int loseNextAnswers = 0;

  /// How many of the next changes fail before they reach the server (a
  /// network error): nothing is applied.
  int failNextRequests = 0;

  /// Awaited before every change is applied; a test can hold it open.
  Future<void> Function(StockOp op)? beforeCall;

  /// Every change sent, in order: the op id.
  final List<String> sent = [];

  @override
  Future<StockChangeResult> apply(StockOp op) async {
    await beforeCall?.call(op);
    sent.add(op.opId);
    if (failNextRequests > 0) {
      failNextRequests--;
      throw StateError('stock change ${op.opId} did not reach the server');
    }
    final http = wire;
    final result = http != null
        ? await http.apply(op)
        : StockChangeResult.fromJson(
            core.applyStockChange(
              opId: op.opId,
              medicationId: op.medicationId,
              delta: op.delta,
              setTo: op.setTo,
            ),
          );
    if (loseNextAnswers > 0) {
      loseNextAnswers--;
      throw TimeoutException('answer lost for stock change ${op.opId}');
    }
    return result;
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
