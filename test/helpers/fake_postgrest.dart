/// [FakeServerCore] served over HTTP the way PostgREST answers the requests
/// Medora's real datasources send, so a test can run the real
/// `PostgrestSyncTable`, `PostgrestStockRemote`,
/// `SyncStateRemoteDatasource` and `AccountDataRemoteDatasource` end to end
/// with no network.
///
/// Understood:
/// - `GET` with `select` (the two embeds the app uses), the filters `eq`,
///   `gt`, `gte`, `lt`, `is.null`, `in.(…)` and `or=(…)` with nested
///   `and(…)`, `order` and `limit`;
/// - `PATCH` by `id=eq.…` or `id=in.(…)`, with the conditions of
///   `SyncTable.patch` (`row_version=eq.`, `status=eq.`,
///   `deleted_at=is.null`), run as [FakeServerCore.patch] or
///   [FakeServerCore.patchMany] so request counts match the Dart path;
/// - `POST` with `Prefer: resolution=ignore-duplicates` or
///   `merge-duplicates`, `on_conflict=id` and `columns=…` (a key a row
///   leaves out is stored as null, as PostgREST does without
///   `missing=default`);
/// - `Prefer: return=representation` and the object `Accept` header;
/// - `/rpc/medora_sync_state`, `/rpc/apply_stock_change` and
///   `/rpc/medora_delete_all_data`.
///
/// Anything else answers 400, so a request shape the app starts sending is
/// noticed. A rule the core enforces with a [PostgrestException] (an unknown
/// column, a bad stock change) comes back as the HTTP error PostgREST sends.
///
/// Answers are written as a local Supabase writes them (checked against
/// `supabase start`, CLI 2.117.0): every `timestamptz` in UTC as
/// `…+00:00` with the fraction's trailing zeros dropped (a time sent without
/// an offset is read as UTC, the session's zone), inside `field_edited_at`
/// and the wipe marker too, and a whole `double precision` as a JSON
/// integer. The core keeps what it was sent.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/account_data_remote_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_server.dart';

/// The `timestamptz` columns of the synced tables.
const _timestamptzColumns = {
  'created_at',
  'updated_at',
  'deleted_at',
  'edited_at',
  'start_time',
  'scheduled_time',
  'taken_time',
};

/// [raw] as Postgres writes a `timestamptz` to JSON in a UTC session:
/// `2026-03-01T08:00:00+00:00`, `2026-03-01T08:00:00.5+00:00`. A time
/// without an offset is read as UTC. A value that is no time at all (a
/// test's unreadable row, which Postgres could not hold) is left as it is.
String postgresTimestamptz(String raw) {
  final time = raw.substring(raw.indexOf('T') + 1);
  final zoned = RegExp(r'(Z|[+-]\d\d(:?\d\d)?)$').hasMatch(time);
  final t = DateTime.tryParse(zoned ? raw : '${raw}Z')?.toUtc();
  if (t == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  final micros = t.millisecond * 1000 + t.microsecond;
  final fraction = micros == 0
      ? ''
      : '.${micros.toString().padLeft(6, '0')}'.replaceFirst(
          RegExp(r'0+$'),
          '',
        );
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}$fraction+00:00';
}

/// [row] as PostgREST answers it (see the library comment).
Map<String, dynamic> _asPostgres(Map<String, dynamic> row) => {
  for (final MapEntry(:key, :value) in row.entries)
    key: switch ((key, value)) {
      (_, final String t) when _timestamptzColumns.contains(key) =>
        postgresTimestamptz(t),
      ('dosage_amount', final double d) when d == d.roundToDouble() =>
        d.toInt(),
      ('field_edited_at', final Map<String, dynamic> times) => {
        for (final MapEntry(:key, :value) in times.entries)
          key: value is Map && value['at'] is String
              ? {...value, 'at': postgresTimestamptz(value['at'] as String)}
              : value,
      },
      _ => value,
    },
};

/// The wipe marker of an RPC answer as Postgres writes it.
Map<String, dynamic>? _wipeAsPostgres(Map<String, dynamic>? wipe) =>
    wipe == null
    ? null
    : {...wipe, 'wiped_at': postgresTimestamptz(wipe['wiped_at'] as String)};

class FakePostgrest {
  FakePostgrest(this.core);

  /// The one fake PostgREST in front of [core].
  factory FakePostgrest.of(FakeServerCore core) =>
      _byCore[core] ??= FakePostgrest(core);

  static final _byCore = Expando<FakePostgrest>('FakePostgrest');

  final FakeServerCore core;

  /// Every request, as `METHOD path?query`, in order.
  final List<String> log = [];

  /// When false, `/rpc/medora_sync_state` answers PGRST202 as a project
  /// without the migration does.
  bool migrated = true;

  late final http.Client httpClient = MockClient(_handle);

  /// A Supabase client whose REST calls this fake answers.
  SupabaseClient client() => SupabaseClient(
    'http://postgrest.test',
    'anon-key',
    httpClient: httpClient,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  late final SupabaseClient _client = client();
  late final _medications = MedicationRemoteDatasource(_client);
  late final Map<String, SyncTable> _tables = {
    'medications': _medications.rows,
    'treatments': TreatmentRemoteDatasource(_client).rows,
    'prescriptions': PrescriptionRemoteDatasource(_client).rows,
    'dose_logs': DoseLogRemoteDatasource(_client).rows,
  };

  /// The app's own `PostgrestSyncTable` for [name], talking to this fake.
  SyncTable table(String name) =>
      _tables[name] ?? PostgrestSyncTable(_client, name);

  /// The app's own `PostgrestStockRemote`, talking to this fake.
  StockRemote stock() => _medications.stock;

  /// The app's own `SyncStateRemoteDatasource`, talking to this fake.
  late final SyncStateRemoteDatasource state = SyncStateRemoteDatasource(
    _client,
  );

  /// The app's own `AccountDataRemoteDatasource`, talking to this fake.
  late final AccountDataRemoteDatasource accountData =
      AccountDataRemoteDatasource(_client);

  static const _reserved = {
    'select',
    'order',
    'limit',
    'on_conflict',
    'columns',
  };

  /// The conditions `SyncTable.patch` and `patchMany` may add to the id.
  static const _patchConditions = {'row_version', 'status', 'deleted_at'};

  Future<http.Response> _handle(http.Request request) async {
    log.add('${request.method} ${request.url.path}?${request.url.query}');
    try {
      return _route(request);
    } on PostgrestException catch (e) {
      return _error(request, _statusOf(e.code), e.code ?? 'P0001', e.message);
    } on FormatException catch (e) {
      return _error(request, 400, 'PGRST100', e.message);
    }
  }

  /// The HTTP status PostgREST sends for a Postgres or PostgREST [code].
  static int _statusOf(String? code) => switch (code) {
    'PGRST202' => 404,
    'PGRST116' => 406,
    '28000' => 403,
    '42501' => 403,
    _ => 400,
  };

  http.Response _route(http.Request request) {
    final segments = request.url.pathSegments;
    if (segments.length < 3 || segments[0] != 'rest' || segments[1] != 'v1') {
      return _error(request, 404, 'PGRST125', 'no such route');
    }
    if (segments[2] == 'rpc' && segments.length == 4) {
      if (request.method != 'POST') {
        return _error(request, 400, 'PGRST000', 'rpc over ${request.method}');
      }
      return _rpc(request, segments[3]);
    }
    if (segments.length != 3) {
      return _error(request, 404, 'PGRST125', 'no such route');
    }
    final table = segments[2];
    if (!serverColumns.containsKey(table)) {
      return _error(
        request,
        404,
        'PGRST205',
        "Could not find the table 'public.$table' in the schema cache",
      );
    }
    final query = request.url.queryParametersAll;
    final select = query['select']?.single ?? '*';
    final filters = <String, List<String>>{
      for (final e in query.entries)
        if (!_reserved.contains(e.key)) e.key: e.value,
    };
    final prefer = request.headers['Prefer'] ?? '';
    final representation = prefer.contains('return=representation');
    switch (request.method) {
      case 'GET':
        _count(table, filters);
        var rows = [
          for (final r in core.rowsOf(table).values)
            if (_matchesAll(r, filters)) Map<String, dynamic>.of(r),
        ];
        rows = _ordered(rows, query['order']?.single);
        final limit = int.tryParse(query['limit']?.single ?? '');
        final cap = limit == null
            ? core.rowCap
            : (limit < core.rowCap ? limit : core.rowCap);
        rows = rows.take(cap).toList();
        return _rows(request, table, select, rows);
      case 'PATCH':
        final changes = jsonDecode(request.body);
        if (changes is! Map<String, dynamic>) {
          return _error(request, 400, 'PGRST102', 'not an object');
        }
        final written = _patch(table, filters, changes);
        if (written == null) {
          return _error(
            request,
            400,
            'PGRST000',
            'unsupported update filter ${request.url.query}',
          );
        }
        return representation
            ? _rows(request, table, select, written)
            : http.Response('', 204, request: request);
      case 'POST':
        if (filters.isNotEmpty) {
          return _error(request, 400, 'PGRST000', 'filters on an insert');
        }
        if (query['on_conflict'] case final c? when c.single != 'id') {
          return _error(request, 400, 'PGRST000', 'on_conflict=${c.single}');
        }
        final body = jsonDecode(request.body);
        final rows = [
          for (final r in body is List ? body : [body])
            Map<String, dynamic>.from(r as Map),
        ];
        final columns = query['columns']?.single;
        final List<Map<String, dynamic>> shaped;
        if (columns != null) {
          final names = [for (final c in _split(columns)) _unquote(c)];
          // Keys outside `columns` are ignored; a listed key a row leaves
          // out is null (no `missing=default`).
          shaped = [
            for (final r in rows) {for (final n in names) n: r[n]},
          ];
        } else {
          if (rows.any(
            (r) =>
                r.length != rows.first.length ||
                !r.keys.every(rows.first.containsKey),
          )) {
            return _error(
              request,
              400,
              'PGRST102',
              'All object keys must match',
            );
          }
          shaped = rows;
        }
        if (prefer.contains('resolution=ignore-duplicates')) {
          core.insertIfAbsent(table, shaped);
        } else if (prefer.contains('resolution=merge-duplicates')) {
          for (final r in shaped) {
            core.legacyUpsert(table, r);
          }
        } else {
          return _error(request, 400, 'PGRST000', 'plain insert');
        }
        if (!representation) {
          return http.Response('', 201, request: request);
        }
        final stored = [
          for (final r in shaped)
            Map<String, dynamic>.of(core.rowsOf(table)[r['id']]!),
        ];
        return _rows(request, table, select, stored, status: 201);
    }
    return _error(
      request,
      400,
      'PGRST000',
      'unsupported ${request.method} on $table',
    );
  }

  http.Response _rpc(http.Request request, String fn) {
    final decoded = request.body.isEmpty ? null : jsonDecode(request.body);
    final params = decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
    switch (fn) {
      case 'medora_sync_state':
        if (!migrated) {
          return _error(
            request,
            404,
            'PGRST202',
            'Could not find the function public.medora_sync_state without '
                'parameters in the schema cache',
          );
        }
        final state = core.syncState();
        return _json(request, {
          ...state,
          'wipe': _wipeAsPostgres(state['wipe'] as Map<String, dynamic>?),
        });
      case 'apply_stock_change':
        const known = {'p_op_id', 'p_medication_id', 'p_delta', 'p_set_to'};
        if (!known.containsAll(params.keys)) {
          return _error(
            request,
            404,
            'PGRST202',
            'Could not find the function '
                'public.apply_stock_change(${(params.keys.toList()..sort()).join(', ')}) '
                'in the schema cache',
          );
        }
        return _json(
          request,
          core.applyStockChange(
            opId: params['p_op_id'] as String,
            medicationId: params['p_medication_id'] as String,
            delta: params['p_delta'] as int?,
            setTo: params['p_set_to'] as int?,
          ),
        );
      case 'medora_delete_all_data':
        if (!migrated) {
          return _error(
            request,
            404,
            'PGRST202',
            'Could not find the function public.medora_delete_all_data '
                'without parameters in the schema cache',
          );
        }
        return _json(request, _wipeAsPostgres(core.deleteAllData()));
    }
    return _error(
      request,
      404,
      'PGRST202',
      'Could not find the function public.$fn without parameters in the '
          'schema cache',
    );
  }

  /// Records a read in [FakeServerCore.requests] the way the core's own
  /// `page`, `fetch` and `fetchMany` do.
  void _count(String table, Map<String, List<String>> filters) {
    if (filters.containsKey('sync_xid')) {
      core.requests.add('$table:page');
      return;
    }
    final id = filters['id'];
    if (id == null) {
      core.requests.add('$table:select');
    } else if (id.single.startsWith('in.')) {
      core.requests.add('$table:fetchMany');
    } else {
      core.requests.add('$table:fetch');
    }
  }

  /// The two update shapes the app sends: `id=eq.…` ([FakeServerCore.patch])
  /// or `id=in.(…)` ([FakeServerCore.patchMany]), each with the conditions
  /// of `SyncTable.patch`. Null for any other filter set.
  List<Map<String, dynamic>>? _patch(
    String table,
    Map<String, List<String>> filters,
    Map<String, dynamic> changes,
  ) {
    final ids = filters['id'];
    if (ids == null || ids.length != 1) return null;
    if (!filters.keys.every((k) => k == 'id' || _patchConditions.contains(k))) {
      return null;
    }
    String? eq(String column) {
      final values = filters[column];
      if (values == null) return null;
      final v = values.single;
      if (!v.startsWith('eq.')) throw FormatException('$column=$v');
      return _unquote(v.substring(3));
    }

    final live = filters['deleted_at'];
    if (live != null && live.single != 'is.null') {
      throw FormatException('deleted_at=${live.single}');
    }
    final version = eq('row_version');
    final ifVersion = version == null ? null : int.parse(version);
    final ifStatus = eq('status');
    final id = ids.single;
    if (id.startsWith('in.')) {
      return core.patchMany(
        table,
        [for (final v in _split(_inner(id.substring(3)))) _unquote(v)],
        changes,
        ifVersion: ifVersion,
        ifStatus: ifStatus,
        ifLive: live != null,
      );
    }
    final row = core.patch(
      table,
      eq('id')!,
      changes,
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: live != null,
    );
    return [?row];
  }

  // ── Filters ────────────────────────────────────────────────

  bool _matchesAll(
    Map<String, dynamic> row,
    Map<String, List<String>> filters,
  ) {
    for (final e in filters.entries) {
      for (final value in e.value) {
        final ok = e.key == 'or'
            ? _or(row, _inner(value))
            : e.key == 'and'
            ? _and(row, _inner(value))
            : _test(row, e.key, value);
        if (!ok) return false;
      }
    }
    return true;
  }

  static String _inner(String grouped) {
    if (!grouped.startsWith('(') || !grouped.endsWith(')')) {
      throw FormatException('not a group: $grouped');
    }
    return grouped.substring(1, grouped.length - 1);
  }

  bool _or(Map<String, dynamic> row, String list) =>
      _split(list).any((c) => _condition(row, c));

  bool _and(Map<String, dynamic> row, String list) =>
      _split(list).every((c) => _condition(row, c));

  bool _condition(Map<String, dynamic> row, String c) {
    if (c.startsWith('and(')) return _and(row, _inner(c.substring(3)));
    if (c.startsWith('or(')) return _or(row, _inner(c.substring(2)));
    final dot = c.indexOf('.');
    if (dot < 0) throw FormatException('not a condition: $c');
    return _test(row, c.substring(0, dot), c.substring(dot + 1));
  }

  /// Splits a PostgREST list at the commas outside quotes and parentheses.
  static List<String> _split(String list) {
    final parts = <String>[];
    final current = StringBuffer();
    var depth = 0;
    var quoted = false;
    for (var i = 0; i < list.length; i++) {
      final ch = list[i];
      if (quoted) {
        current.write(ch);
        if (ch == r'\' && i + 1 < list.length) {
          current.write(list[++i]);
        } else if (ch == '"') {
          quoted = false;
        }
        continue;
      }
      if (ch == '"') quoted = true;
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    if (current.isNotEmpty) parts.add(current.toString());
    return parts;
  }

  static String _unquote(String v) {
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      final inner = v.substring(1, v.length - 1);
      final out = StringBuffer();
      for (var i = 0; i < inner.length; i++) {
        if (inner[i] == r'\' && i + 1 < inner.length) i++;
        out.write(inner[i]);
      }
      return out.toString();
    }
    return v;
  }

  static bool _test(Map<String, dynamic> row, String column, String expr) {
    if (!row.containsKey(column)) {
      throw PostgrestException(
        message: 'column $column does not exist',
        code: '42703',
      );
    }
    final dot = expr.indexOf('.');
    if (dot < 0) throw FormatException('unsupported filter $column=$expr');
    final op = expr.substring(0, dot);
    final raw = expr.substring(dot + 1);
    final actual = row[column];
    switch (op) {
      case 'is':
        return switch (raw) {
          'null' => actual == null,
          'true' => actual == true,
          'false' => actual == false,
          _ => throw FormatException('unsupported filter $column=$expr'),
        };
      case 'in':
        return _split(_inner(raw)).map(_unquote).contains('$actual');
      case 'eq':
      case 'gt':
      case 'gte':
      case 'lt':
        if (actual == null) return false;
        final expected = _unquote(raw);
        final int cmp;
        if (actual is num) {
          cmp = actual.compareTo(num.parse(expected));
        } else if (actual is bool) {
          cmp = '$actual' == expected ? 0 : 1;
        } else {
          cmp = '$actual'.compareTo(expected);
        }
        return switch (op) {
          'eq' => cmp == 0,
          'gt' => cmp > 0,
          'gte' => cmp >= 0,
          _ => cmp < 0,
        };
    }
    throw FormatException('unsupported filter $column=$expr');
  }

  static List<Map<String, dynamic>> _ordered(
    List<Map<String, dynamic>> rows,
    String? order,
  ) {
    if (order == null) return rows;
    final keys = [
      for (final part in order.split(','))
        (part.split('.').first, !part.split('.').contains('desc')),
    ];
    return rows..sort((a, b) {
      for (final (column, ascending) in keys) {
        final x = a[column];
        final y = b[column];
        final cmp = x is num && y is num
            ? x.compareTo(y)
            : '$x'.compareTo('$y');
        if (cmp != 0) return ascending ? cmp : -cmp;
      }
      return 0;
    });
  }

  // ── Answers ────────────────────────────────────────────────

  http.Response _rows(
    http.Request request,
    String table,
    String select,
    List<Map<String, dynamic>> rows, {
    int status = 200,
  }) {
    final shaped = [
      for (final r in rows) _asPostgres(_embed(table, select, r)),
    ];
    final accept = request.headers['Accept'] ?? '';
    if (accept.contains('vnd.pgrst.object+json')) {
      if (shaped.length != 1) {
        return _error(
          request,
          406,
          'PGRST116',
          'Cannot coerce the result to a single JSON object',
          details: 'The result contains ${shaped.length} rows',
        );
      }
      return _json(request, shaped.single, status: status);
    }
    return _json(request, shaped, status: status);
  }

  /// The two embeds the app asks for; any other `select` than `*` plus
  /// these is refused.
  Map<String, dynamic> _embed(
    String table,
    String select,
    Map<String, dynamic> row,
  ) {
    final out = Map<String, dynamic>.of(row);
    switch ((table, select)) {
      case (_, '*'):
        break;
      case ('dose_logs', '*,prescriptions(id,medications(name))'):
        final p = core.rowsOf('prescriptions')[row['prescription_id']];
        final m = p == null
            ? null
            : core.rowsOf('medications')[p['medication_id']];
        out['prescriptions'] = p == null
            ? null
            : {
                'id': p['id'],
                'medications': m == null ? null : {'name': m['name']},
              };
      case ('prescriptions', '*,medications(name),treatments(name)'):
        final m = core.rowsOf('medications')[row['medication_id']];
        final t = core.rowsOf('treatments')[row['treatment_id']];
        out['medications'] = m == null ? null : {'name': m['name']};
        out['treatments'] = t == null ? null : {'name': t['name']};
      default:
        throw FormatException('unsupported select on $table: $select');
    }
    return out;
  }

  static http.Response _json(
    http.Request request,
    Object? body, {
    int status = 200,
  }) => http.Response(
    jsonEncode(body),
    status,
    request: request,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(
    http.Request request,
    int status,
    String code,
    String message, {
    String? details,
  }) => http.Response(
    jsonEncode({
      'code': code,
      'message': message,
      'details': details,
      'hint': null,
    }),
    status,
    request: request,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
