/// Sync v2 against a local Supabase (`supabase start`) with every migration
/// applied: what only the real PostgREST and the real `supabase/postgres`
/// image can show.
///
/// - "Delete all data" runs with its owner's rights (Supabase's `postgres`
///   role) and still removes only the caller's rows; the wipe marker
///   reaches the other device; an insert from a device that has not seen
///   the wipe lands deleted.
/// - The bulk update `PATCH ?id=in.(…)` keeps its conditions per row and
///   answers with the embedded prescription.
/// - Paged reads continue after an id full of PostgREST syntax.
/// - `.single()` after an upsert or an update under row-level security.
/// - A batch of new doses that deadlocks with a request deleting their
///   prescriptions is sent again one by one, and every dose ends deleted
///   with its prescription.
///
/// Run (see `local_supabase.dart`):
///   fvm flutter test test/integration --concurrency=1 \
///     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///     --dart-define=SUPABASE_ANON_KEY="$ANON_KEY" \
///     --dart-define=SUPABASE_DB_CONTAINER=supabase_db_medora
///
/// (`ANON_KEY` as `supabase status -o env` prints it; the container is
/// `supabase_db_` followed by the project id.)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/account_data_remote_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';
import 'local_supabase.dart';

const _uuid = Uuid();
final _epoch = DateTime.utc(1970).toIso8601String();

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final skip = localSupabaseConfigured ? false : localSupabaseSkip;

  test(
    '"delete all data" removes only the caller\'s rows and ledger, the '
    'other device follows the wipe, and a stale insert lands deleted',
    () async {
      final owner = await signUp();
      final bystander = await signUp();
      final folder = await deviceFolder();
      final a = LocalDevice('A', '$folder/a.db', owner.client, owner.userId);
      final b = LocalDevice('B', '$folder/b.db', owner.client, owner.userId);
      final medId = _uuid.v4();
      final treatmentId = _uuid.v4();
      await a.run((_) async {
        await a.medications.addMedication(
          Medication(id: medId, name: 'Ibuprofen 400', quantity: 10),
        );
        await a.treatments.addTreatment(
          Treatment(
            id: treatmentId,
            name: 'Sinusitis',
            startDate: DateTime(2026, 3, 2),
          ),
        );
      });
      // Once the medication is on the server, a stock change goes out as
      // one (before that it is folded into the insert).
      await a.run((_) => a.medications.updateQuantity(medId, -1));
      await a.sync();
      await b.sync();
      expect(await b.rows('medications', medId), hasLength(1));
      // B renames the medication offline, before the wipe.
      b.online = false;
      await b.run((_) async {
        final m = (await b.medications.getMedicationById(medId)).dataOrNull!;
        await b.medications.updateMedication(m.copyWith(name: 'Renamed on B'));
      });
      final notMine = _uuid.v4();
      await bystander.client.from('medications').insert({
        'id': notMine,
        'user_id': bystander.userId,
        'name': 'Not mine',
      });
      final ledgerBefore = await owner.client
          .from('stock_changes')
          .select('delta')
          .eq('medication_id', medId);
      expect(ledgerBefore, [
        {'delta': -1},
      ]);

      // A signed-out client cannot call it.
      await expectLater(
        anonymousClient().rpc<dynamic>('medora_delete_all_data'),
        throwsA(isA<PostgrestException>()),
      );

      await AccountDataRemoteDatasource(owner.client).deleteAllData();

      final state = await SyncStateRemoteDatasource(owner.client).read();
      expect(state.wipeGeneration, 1);
      expect(state.wipedAt, isNotNull);
      for (final table in const [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
        'stock_changes',
      ]) {
        expect(await owner.client.from(table).select(), isEmpty, reason: table);
      }
      final kept = await bystander.client
          .from('medications')
          .select('id, name')
          .eq('id', notMine);
      expect(kept, [
        {'id': notMine, 'name': 'Not mine'},
      ]);
      final bystanderState = await SyncStateRemoteDatasource(
        bystander.client,
      ).read();
      expect(bystanderState.wipeGeneration, 0);

      // B follows the wipe: its copies go, and its rename is never sent.
      b.online = true;
      await b.sync();
      expect(await b.rows('medications', medId), isEmpty);
      expect(await b.rows('treatments', treatmentId), isEmpty);
      await a.sync();
      expect(await a.rows('medications', medId), isEmpty);
      expect(await owner.client.from('medications').select(), isEmpty);

      // A medication added after the wipe is uploaded as usual.
      final after = _uuid.v4();
      await a.run(
        (_) => a.medications.addMedication(
          Medication(id: after, name: 'After the wipe', quantity: 1),
        ),
      );
      expect(await owner.client.from('medications').select('id, deleted_at'), [
        {'id': after, 'deleted_at': null},
      ]);

      // A device that has not seen the wipe inserts a row a person changed
      // before it: it lands deleted, as that person's delete.
      final stale = _uuid.v4();
      await MedicationRemoteDatasource(owner.client).rows.insertIfAbsent([
        {
          'id': stale,
          'user_id': owner.userId,
          'name': 'Stale',
          'write_id': _uuid.v4(),
          'edited_at': state.wipedAt!
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
          'field_edited_at': {'@wipe': 0},
        },
      ]);
      final landed = (await MedicationRemoteDatasource(
        owner.client,
      ).rows.fetch(stale))!;
      expect(landed['deleted_at'], isNotNull);
      expect(
        DateTime.parse(landed['deleted_at'] as String),
        state.wipedAt,
        reason: 'deleted at the wipe',
      );
      expect((landed['field_edited_at'] as Map).containsKey('@wipe'), isFalse);

      // A second wipe moves the generation on.
      await AccountDataRemoteDatasource(owner.client).deleteAllData();
      expect(
        (await SyncStateRemoteDatasource(owner.client).read()).wipeGeneration,
        2,
      );
    },
    skip: skip,
  );

  test('a bulk update by id keeps its conditions per row and answers with the '
      'embedded prescription', () async {
    final acct = await signUp();
    final ids = await _seedSchedule(acct.client, acct.userId, doses: 103);
    final doses = DoseLogRemoteDatasource(acct.client).rows;
    final taken = ids.doses[0];
    final skipped = ids.doses[1];
    final deleted = ids.doses[2];
    final before = {
      for (final r in await doses.fetchMany(ids.doses.sublist(0, 100)))
        r['id'] as String: r,
    };
    expect(before, hasLength(100));
    expect(before[skipped]!['status'], 'skipped');
    expect(before[deleted]!['deleted_at'], isNotNull);
    final took = await doses.patch(
      taken,
      {
        'status': 'taken',
        'taken_time': DateTime.now().toUtc().toIso8601String(),
        'write_id': _uuid.v4(),
        'edited_at': DateTime.now().toUtc().toIso8601String(),
      },
      ifVersion: 1,
      ifStatus: 'pending',
      ifLive: true,
    );
    expect(took!['row_version'], 2);
    expect(took['prescriptions'], {
      'id': ids.prescription,
      'medications': {'name': 'Bulk'},
    });

    final writeId = _uuid.v4();
    final written = await doses.patchMany(
      ids.doses.sublist(0, 100),
      {
        'status': 'missed',
        'write_id': writeId,
        'edited_at': _epoch,
        'field_edited_at': {
          'status': {'at': _epoch, 'auto': true},
        },
      },
      ifVersion: 1,
      ifStatus: 'pending',
      ifLive: true,
    );
    expect(written, hasLength(97));
    expect(
      written.map((r) => r['id']),
      isNot(anyOf(contains(taken), contains(skipped), contains(deleted))),
    );
    for (final r in written) {
      expect(r['status'], 'missed');
      expect(r['row_version'], 2);
      expect(r['write_id'], writeId);
      expect(DateTime.parse(r['edited_at'] as String), DateTime.utc(1970));
      // The app's own change: 0.3.0 does not see it.
      expect(
        DateTime.parse(r['updated_at'] as String),
        DateTime.parse(before[r['id']]!['updated_at'] as String),
      );
      expect(r['prescriptions'], {
        'id': ids.prescription,
        'medications': {'name': 'Bulk'},
      });
    }
    final after = {
      for (final r in await doses.fetchMany([taken, skipped, deleted]))
        r['id'] as String: r['status'],
    };
    expect(after, {taken: 'taken', skipped: 'skipped', deleted: 'pending'});
    // The same update again writes nothing: every row moved on.
    expect(
      await doses.patchMany(
        ids.doses.sublist(0, 100),
        {'status': 'missed', 'write_id': _uuid.v4(), 'edited_at': _epoch},
        ifVersion: 1,
        ifStatus: 'pending',
        ifLive: true,
      ),
      isEmpty,
    );
  }, skip: skip);

  test('paged reads continue after an id full of PostgREST syntax', () async {
    final acct = await signUp();
    final tag = _uuid.v4();
    final ids = [
      for (final odd in const ['a"b', 'a,b', 'a)b', 'a.b', r'a\b', 'a(b'])
        'pg-$tag-$odd',
    ];
    await MedicationRemoteDatasource(acct.client).rows.insertIfAbsent([
      for (final id in ids) {'id': id, 'user_id': acct.userId, 'name': id},
    ]);
    final horizon = (await SyncStateRemoteDatasource(
      acct.client,
    ).read()).horizon;
    final seen = <String>[];
    PullKey? after;
    for (var i = 0; i < 10; i++) {
      final page = await pullPage(
        acct.client.from('medications').select(),
        after: after,
        horizon: horizon,
        limit: 2,
      );
      seen.addAll([for (final r in page) r['id'] as String]);
      final next = afterPullPage(page, horizon: horizon);
      after = next.key;
      if (next.done) break;
    }
    expect(seen, [...ids]..sort());
    // From a transaction id only: the first row of that transaction on.
    final xid =
        (await acct.client
                .from('medications')
                .select('sync_xid')
                .eq('id', ids.first)
                .single())['sync_xid']
            as int;
    final fromXid = await pullPage(
      acct.client.from('medications').select(),
      after: PullKey(xid),
      horizon: horizon,
    );
    expect(fromXid.map((r) => r['id']), [...ids]..sort());
  }, skip: skip);

  test(
    '.single() after an upsert or an update under row-level security',
    () async {
      final acct = await signUp();
      final other = await signUp();
      final id = _uuid.v4();
      // Medora 0.3.0's write: a whole-row upsert, read back as one object.
      Future<Map<String, dynamic>> upsert(String name) => acct.client
          .from('medications')
          .upsert({
            'id': id,
            'user_id': acct.userId,
            'name': name,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('updated_at, row_version, write_id')
          .single();
      final first = await upsert('One');
      expect(first['row_version'], 1);
      final second = await upsert('Two');
      expect([second['row_version'], second['write_id']], [2, null]);
      // Another account's upsert of the same id is refused.
      await expectLater(
        other.client
            .from('medications')
            .upsert({'id': id, 'user_id': other.userId, 'name': 'Mine'})
            .select()
            .single(),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      // An update that matches no visible row answers PGRST116 to
      // `.single()`, and null to the app's conditional write.
      await expectLater(
        other.client
            .from('medications')
            .update({'name': 'Mine'})
            .eq('id', id)
            .select()
            .single(),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', 'PGRST116'),
        ),
      );
      expect(
        await MedicationRemoteDatasource(
          other.client,
        ).rows.patch(id, {'name': 'Mine', 'write_id': _uuid.v4()}),
        isNull,
      );
      expect(
        await MedicationRemoteDatasource(other.client).rows.fetch(id),
        isNull,
      );
      final stored = await MedicationRemoteDatasource(
        acct.client,
      ).rows.fetch(id);
      expect(stored!['name'], 'Two');
    },
    skip: skip,
  );

  test(
    'a stock change is applied once, and a retry answers duplicate',
    () async {
      final acct = await signUp();
      final id = _uuid.v4();
      await MedicationRemoteDatasource(acct.client).rows.insertIfAbsent([
        {'id': id, 'user_id': acct.userId, 'name': 'Stock', 'quantity': 5},
      ]);
      final stock = MedicationRemoteDatasource(acct.client).stock;
      final op = _uuid.v4();
      final applied = await stock.apply(_op(op, id, delta: -2000000));
      expect(
        [applied.status, applied.quantity],
        [StockChangeStatus.applied, 0],
      );
      final again = await stock.apply(_op(op, id, delta: -2000000));
      expect([again.status, again.quantity], [StockChangeStatus.duplicate, 0]);
      final gone = await stock.apply(_op(_uuid.v4(), _uuid.v4(), setTo: 3));
      expect(gone.status, StockChangeStatus.gone);
    },
    skip: skip,
  );

  test(
    'a batch of new doses that deadlocks with a delete of their '
    'prescriptions is sent again one by one; every dose ends deleted',
    () async {
      final acct = await signUp();
      final folder = await deviceFolder();
      final a = LocalDevice('A', '$folder/a.db', acct.client, acct.userId);
      late String first;
      late String second;
      await a.run((db) async {
        final p1 = await seedPrescription(
          db,
          startTime: DateTime(2026, 3, 1, 8),
          intervalHours: 24,
          durationDays: 1,
        );
        final p2 = await seedPrescription(
          db,
          startTime: DateTime(2026, 3, 1, 9),
          intervalHours: 24,
          durationDays: 1,
        );
        first = p1.prescriptionId;
        second = p2.prescriptionId;
        for (final t in ['medications', 'treatments', 'prescriptions']) {
          await db.update(t, {'sync_status': SyncStatus.pendingCreate});
        }
      });
      await a.sync();
      // Two new doses, one per prescription, in one batch: the first
      // prescription is locked first.
      await a.run((db) async {
        await seedDoseLog(db, first, DateTime(2026, 3, 1, 8));
        await seedDoseLog(db, second, DateTime(2026, 3, 1, 9));
        await db.update('dose_logs', {'sync_status': SyncStatus.pendingCreate});
      });

      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        logs.add(message ?? '');
        original(message, wrapWidth: wrapWidth);
      };
      final session = await _Psql.open();
      try {
        // Another request deletes both prescriptions, the second first,
        // and never detects the deadlock itself.
        await session.run(
          "set deadlock_timeout = '20s'; begin; "
          '${_deletePrescription(second)}',
        );
        final cycle = a.run((_) => a.service.syncAll());
        await _waitForLockWait('dose_logs');
        final both = session.run(_deletePrescription(first));
        await both.timeout(const Duration(seconds: 15));
        await session.run('commit;');
        final report = (await cycle)!;
        expect(
          logs,
          contains(contains('refused a batch of 2 dose logs (40P01)')),
          reason: 'the batch insert must have been the deadlock victim',
        );
        expect(
          report.isClean,
          isTrue,
          reason: '${report.fatal} ${report.failures}',
        );
      } finally {
        debugPrint = original;
        await session.close();
      }

      final server = await acct.client
          .from('dose_logs')
          .select('prescription_id, deleted_at, edited_at')
          .inFilter('prescription_id', [first, second]);
      expect(server, hasLength(2));
      for (final d in server) {
        expect(d['deleted_at'], isNotNull, reason: '$d');
        expect(DateTime.parse(d['edited_at'] as String), DateTime.utc(1970));
      }
      await a.sync();
      final local = await a.run(
        (db) => db.query(
          'dose_logs',
          where: 'deleted_at IS NULL OR sync_status != ?',
          whereArgs: [SyncStatus.synced],
        ),
      );
      expect(local, isEmpty);
    },
    skip: localSupabaseConfigured && supabaseDbContainer.isNotEmpty
        ? false
        : '$localSupabaseSkip, and SUPABASE_DB_CONTAINER',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

StockOp _op(String opId, String medicationId, {int? delta, int? setTo}) =>
    StockOp(
      opId: opId,
      medicationId: medicationId,
      delta: delta,
      setTo: setTo,
      createdAt: DateTime.now().toUtc(),
    );

String _deletePrescription(String id) =>
    'update public.prescriptions set deleted_at = now(), '
    "write_id = gen_random_uuid(), edited_at = now() where id = '$id';";

/// A medication, a treatment, a prescription and [doses] pending doses of
/// the account, sent the way 0.4.0 sends new rows. The second dose is
/// skipped, the third deleted.
Future<({String prescription, List<String> doses})> _seedSchedule(
  SupabaseClient client,
  String userId, {
  required int doses,
}) async {
  final med = _uuid.v4();
  final treatment = _uuid.v4();
  final prescription = _uuid.v4();
  await MedicationRemoteDatasource(client).rows.insertIfAbsent([
    {'id': med, 'user_id': userId, 'name': 'Bulk'},
  ]);
  await TreatmentRemoteDatasource(client).rows.insertIfAbsent([
    {
      'id': treatment,
      'user_id': userId,
      'name': 'Bulk',
      'start_date': '2026-03-01',
    },
  ]);
  await PrescriptionRemoteDatasource(client).rows.insertIfAbsent([
    {
      'id': prescription,
      'treatment_id': treatment,
      'medication_id': med,
      'dosage': '1',
      'start_time': '2026-03-01T08:00:00Z',
    },
  ]);
  final ids = [for (var i = 0; i < doses; i++) _uuid.v4()];
  await DoseLogRemoteDatasource(client).rows.insertIfAbsent([
    for (var i = 0; i < doses; i++)
      {
        'id': ids[i],
        'prescription_id': prescription,
        'scheduled_time': DateTime.utc(
          2026,
          3,
          1,
          8,
        ).add(Duration(hours: i)).toIso8601String(),
        'status': i == 1 ? 'skipped' : 'pending',
        'deleted_at': i == 2 ? DateTime.now().toUtc().toIso8601String() : null,
        'write_id': _uuid.v4(),
        'edited_at': _epoch,
        'updated_at': _epoch,
        'field_edited_at': <String, Object?>{},
      },
  ]);
  return (prescription: prescription, doses: ids);
}

/// Waits until a request on [table] waits for a lock.
Future<void> _waitForLockWait(String table) async {
  for (var i = 0; i < 100; i++) {
    final waiting = await _Psql.query(
      'select count(*) from pg_locks l join pg_stat_activity a using (pid) '
      "where not l.granted and a.query ilike '%$table%'",
    );
    if (waiting != '0') return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('no request on $table ever waited for a lock');
}

/// A `psql` session in the local stack's database container, as its
/// superuser, whose transaction stays open between statements.
class _Psql {
  _Psql._(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final waiter = _waiting.remove(line.trim());
          waiter?.complete();
        });
    _process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  /// The container's own password variable is handed to psql inside it,
  /// so the test never reads it.
  static List<String> _args(List<String> extra) => [
    'exec',
    '-i',
    supabaseDbContainer,
    'sh',
    '-c',
    r'PGPASSWORD="$POSTGRES_PASSWORD" exec psql "$@"',
    'sh',
    '-X',
    '-q',
    '-U',
    'supabase_admin',
    '-d',
    'postgres',
    ...extra,
  ];

  static Future<_Psql> open() async =>
      _Psql._(await Process.start('docker', _args(const [])));

  /// One statement in its own session; its only output line.
  static Future<String> query(String sql) async {
    final result = await Process.run('docker', _args(['-At', '-c', sql]));
    if (result.exitCode != 0) fail('psql: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  final Process _process;
  final Map<String, Completer<void>> _waiting = {};
  var _marks = 0;

  /// Sends [sql]; completes once psql has run it.
  Future<void> run(String sql) {
    final mark = 'medora-mark-${_marks++}';
    final done = _waiting[mark] = Completer<void>();
    _process.stdin.writeln(sql);
    _process.stdin.writeln('\\echo $mark');
    return done.future;
  }

  /// Ends the session; a transaction still open is rolled back.
  Future<void> close() async {
    _process.stdin.writeln('\\q');
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}
