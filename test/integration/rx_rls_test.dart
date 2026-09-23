/// Prescriptions against a local Supabase (`supabase start`) with every
/// migration applied: row-level security, the tombstone cascade, the parent
/// trigger and "delete all data" on `persons`, `rx` and `rx_dispensings`,
/// through the real PostgREST and [RxRemoteDatasource].
///
/// Run (see `local_supabase.dart`):
///   fvm flutter test test/integration/rx_rls_test.dart \
///     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///     --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/account_data_remote_datasource.dart';
import 'package:medora/data/datasources/rx_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'local_supabase.dart';

const _uuid = Uuid();
final _epoch = DateTime.utc(1970);

/// The bookkeeping the app sends with a person's write.
Map<String, Object?> _written() => {
  'write_id': _uuid.v4(),
  'edited_at': DateTime.now().toUtc().toIso8601String(),
  'field_edited_at': <String, Object?>{},
};

/// A signed-in account with a person, a prescription for them and one
/// dispensing of it, all written through [RxRemoteDatasource].
class _Owner {
  _Owner(this.client, this.userId) : remote = RxRemoteDatasource(client);

  final SupabaseClient client;
  final String userId;
  final RxRemoteDatasource remote;
  final personId = _uuid.v4();
  final rxId = _uuid.v4();
  final dispensingId = _uuid.v4();

  static Future<_Owner> create() async {
    final account = await signUp();
    final owner = _Owner(account.client, account.userId);
    await owner.remote.persons.insertIfAbsent([
      {
        'id': owner.personId,
        'user_id': owner.userId,
        'name': 'Anna',
        'tax_code': 'RSSNNA80A41H501X',
        ..._written(),
      },
    ]);
    await owner.remote.rx.insertIfAbsent([
      {
        'id': owner.rxId,
        'user_id': owner.userId,
        'person_id': owner.personId,
        'kind': 'ssn',
        'nre': '1200A1234567890',
        'issued_on': '2026-09-01',
        'items': [
          {'id': 'i1', 'name': 'Tachipirina 500', 'packs': 2},
        ],
        ..._written(),
      },
    ]);
    await owner.dispense(owner.dispensingId);
    return owner;
  }

  Future<void> dispense(String id, {String? rxId}) =>
      remote.dispensings.insertIfAbsent([
        {
          'id': id,
          'user_id': userId,
          'rx_id': rxId ?? this.rxId,
          'item_id': 'i1',
          'packs': 1,
          'dispensed_on': '2026-09-02',
          ..._written(),
        },
      ]);
}

DateTime? _time(Map<String, dynamic>? row, String column) =>
    row?[column] == null ? null : DateTime.parse(row![column] as String);

void main() {
  final skip = localSupabaseConfigured ? false : localSupabaseSkip;

  test('the owner reads back what it wrote, at version 1', () async {
    final a = await _Owner.create();
    final person = await a.remote.persons.fetch(a.personId);
    final rx = await a.remote.rx.fetch(a.rxId);
    final dispensing = await a.remote.dispensings.fetch(a.dispensingId);
    expect(person?['name'], 'Anna');
    expect(rx?['person_id'], a.personId);
    expect(rx?['items'], [
      {'id': 'i1', 'name': 'Tachipirina 500', 'packs': 2},
    ]);
    expect(dispensing?['rx_id'], a.rxId);
    for (final row in [person, rx, dispensing]) {
      expect(row?['row_version'], 1);
      expect(row?['deleted_at'], isNull);
    }
  }, skip: skip);

  test('another account sees none of it and cannot hang a dispensing on '
      'it, neither new nor by moving its own', () async {
    final a = await _Owner.create();
    final b = await _Owner.create();
    expect(await b.remote.persons.fetchMany([a.personId]), isEmpty);
    expect(await b.remote.rx.fetchMany([a.rxId]), isEmpty);
    expect(await b.remote.dispensings.fetchMany([a.dispensingId]), isEmpty);

    await expectLater(
      b.dispense(_uuid.v4(), rxId: a.rxId),
      throwsA(isA<PostgrestException>()),
    );
    // Its own dispensing, pointed at A's prescription (the update policy
    // checks the parent as the insert policy does).
    await expectLater(
      b.remote.dispensings.patch(b.dispensingId, {
        'rx_id': a.rxId,
        ..._written(),
      }),
      throwsA(isA<PostgrestException>()),
    );
    expect(
      (await b.remote.dispensings.fetch(b.dispensingId))?['rx_id'],
      b.rxId,
    );
    // Nor can B change A's rows: the update matches nothing.
    expect(
      await b.remote.rx.patch(a.rxId, {'notes': 'B', ..._written()}),
      isNull,
    );
    expect((await a.remote.rx.fetch(a.rxId))?['notes'], isNull);
  }, skip: skip);

  test('deleting the prescription deletes its dispensing as the app\'s own '
      'change', () async {
    final a = await _Owner.create();
    final deletedAt = DateTime.now().toUtc();
    final rx = await a.remote.rx.patch(a.rxId, {
      'deleted_at': deletedAt.toIso8601String(),
      ..._written(),
    }, ifVersion: 1);
    expect(rx?['row_version'], 2);

    final dispensing = await a.remote.dispensings.fetch(a.dispensingId);
    final cascaded = _time(dispensing, 'deleted_at');
    expect(cascaded, isNotNull);
    expect(cascaded!.isAtSameMomentAs(_time(rx, 'deleted_at')!), isTrue);
    expect(_time(dispensing, 'edited_at'), _epoch);
    expect(dispensing?['row_version'], 2);
  }, skip: skip);

  test('a live dispensing sent under a deleted prescription is stored '
      'deleted', () async {
    final a = await _Owner.create();
    await a.remote.rx.patch(a.rxId, {
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      ..._written(),
    });
    final lateId = _uuid.v4();
    await a.dispense(lateId);

    final late = await a.remote.dispensings.fetch(lateId);
    expect(late, isNotNull);
    expect(_time(late, 'deleted_at'), isNotNull);
    expect(_time(late, 'edited_at'), _epoch);
  }, skip: skip);

  test('"delete all data" removes the caller\'s persons, prescriptions and '
      'dispensings, and only those', () async {
    final a = await _Owner.create();
    final bystander = await _Owner.create();

    await AccountDataRemoteDatasource(a.client).deleteAllData();

    expect(await a.remote.persons.fetchMany([a.personId]), isEmpty);
    expect(await a.remote.rx.fetchMany([a.rxId]), isEmpty);
    expect(await a.remote.dispensings.fetchMany([a.dispensingId]), isEmpty);
    expect(
      await bystander.remote.dispensings.fetch(bystander.dispensingId),
      isNotNull,
    );
    expect(await bystander.remote.rx.fetch(bystander.rxId), isNotNull);
    expect(await bystander.remote.persons.fetch(bystander.personId), isNotNull);
  }, skip: skip);
}
