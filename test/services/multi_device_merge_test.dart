import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';

import '../helpers/test_database.dart';
import '../helpers/two_devices.dart';

void main() {
  for (final transport in FakeTransport.values) {
    group('over ${transport.name}', () => _scenarios(transport));
  }
}

void _scenarios(FakeTransport transport) {
  late TwoDevices h;

  setUp(() async {
    await setUpTestDatabase();
    h = TwoDevices(transport: transport);
    // Three days ago A recorded the illness and the ibuprofen pack; both
    // devices have synced since, and B has changed the stock once.
    h.clock = DateTime.utc(2026, 3, 2, 9);
    await h.a.run((_) async {
      await h.a.treatments.addTreatment(
        Treatment(
          id: 't1',
          name: 'Sinusitis',
          startDate: DateTime(2026, 3, 2),
          sickLeaveFrom: DateTime(2026, 3, 2),
          doctor: 'Dr. Rossi',
        ),
      );
      await h.a.medications.addMedication(
        const Medication(id: 'm1', name: 'Ibuprofen 400', quantity: 12),
      );
    });
    h.advance(const Duration(minutes: 5));
    await h.b.sync();
    await h.b.run((_) => h.b.medications.updateQuantity('m1', -2));
    h.advance(const Duration(minutes: 5));
    await h.a.sync();
    h.clock = DateTime.utc(2026, 3, 5, 8);
    expect((await h.a.row('medications', 'm1'))['quantity'], 10);
    expect((await h.b.row('medications', 'm1'))['quantity'], 10);
  });
  tearDown(() => h.dispose());

  test(
    'S1a: B adds the certificate offline, A ends the illness, B syncs last',
    () async {
      h.b.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 8, 30);
      await h.b.run((_) async {
        final t = (await h.b.treatments.getTreatmentById('t1')).dataOrNull!;
        await h.b.treatments.updateTreatment(
          t.copyWith(sickLeaveRef: 'CERT-B'),
        );
      });
      h.clock = DateTime.utc(2026, 3, 5, 9);
      await h.a.run(
        (_) => h.a.treatments.endTreatment('t1', endSickLeave: true),
      );
      h.b.online = true;
      h.clock = DateTime.utc(2026, 3, 5, 10);
      await h.b.sync();
      await h.a.sync();
      for (final d in [h.a, h.b]) {
        final row = await d.row('treatments', 't1');
        expect(
          [
            row['is_active'],
            row['end_date'],
            row['sick_leave_to'],
            row['sick_leave_ref'],
            row['sync_status'],
          ],
          [0, '2026-03-05', '2026-03-05', 'CERT-B', 'synced'],
          reason: d.name,
        );
      }
      final server = h.core.rowsOf('treatments')['t1']!;
      expect(
        [server['is_active'], server['sick_leave_ref']],
        [false, 'CERT-B'],
      );
    },
  );

  test(
    'S1b: A ends it and syncs; B, offline, adds the certificate later',
    () async {
      h.clock = DateTime.utc(2026, 3, 5, 9);
      await h.a.run(
        (_) => h.a.treatments.endTreatment('t1', endSickLeave: true),
      );
      h.b.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 9, 30);
      await h.b.run((_) async {
        final t = (await h.b.treatments.getTreatmentById('t1')).dataOrNull!;
        await h.b.treatments.updateTreatment(
          t.copyWith(sickLeaveRef: 'CERT-B'),
        );
      });
      h.b.online = true;
      await h.b.sync();
      await h.a.sync();
      for (final d in [h.a, h.b]) {
        final row = await d.row('treatments', 't1');
        expect(
          [
            row['is_active'],
            row['end_date'],
            row['sick_leave_to'],
            row['sick_leave_ref'],
          ],
          [0, '2026-03-05', '2026-03-05', 'CERT-B'],
          reason: d.name,
        );
      }
    },
  );

  test('both offline, each takes one tablet: 10 -> 8 everywhere', () async {
    h.a.online = false;
    h.b.online = false;
    await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
    await h.b.run((_) => h.b.medications.updateQuantity('m1', -1));
    h.a.online = true;
    h.b.online = true;
    await h.a.sync();
    await h.b.sync();
    await h.a.sync();
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 8);
    expect((await h.a.row('medications', 'm1'))['quantity'], 8);
    expect((await h.b.row('medications', 'm1'))['quantity'], 8);
  });

  test('a lost stock answer is sent again and counted once', () async {
    await h.a.run((_) async {
      h.a.online = false;
      await h.a.medications.updateQuantity('m1', -1);
    });
    h.a.online = true;
    h.loseNextStockAnswer();
    final first = await h.a.sync();
    expect(first!.failures.single.table, 'stock_outbox');
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    h.advance(const Duration(hours: 1));
    await h.a.sync();
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    expect((await h.a.row('medications', 'm1'))['quantity'], 9);
  });

  test(
    'a project without the migration stops the cycle before any write',
    () async {
      h.server.state.migrated = false;
      await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
      final before = h.core.requests.length;
      final report = await h.a.sync();
      expect(
        report!.missingMigration,
        'supabase/migrations/20260918000000_sync_v2.sql',
      );
      expect(report.fatal, contains('20260918000000_sync_v2.sql'));
      expect(h.core.requests.sublist(before), isEmpty);
      expect(h.core.rowsOf('medications')['m1']!['quantity'], 10);
      expect(h.a.service.currentState.name, 'error');
    },
  );

  test('a row committed late is pulled on the next cycle', () async {
    final slow = h.core.begin();
    slow.insert('medications', {
      'id': 'm-late',
      'user_id': 'user-a',
      'name': 'Late',
      'quantity': 3,
    });
    // A later write commits first.
    h.core.legacyUpsert('medications', {
      'id': 'm-fast',
      'user_id': 'user-a',
      'name': 'Fast',
      'quantity': 1,
    });
    await h.b.sync();
    await expectLater(h.b.row('medications', 'm-late'), throwsStateError);
    await expectLater(h.b.row('medications', 'm-fast'), throwsStateError);
    slow.commit();
    await h.b.sync();
    expect((await h.b.row('medications', 'm-late'))['quantity'], 3);
    expect((await h.b.row('medications', 'm-fast'))['quantity'], 1);
  });
}
