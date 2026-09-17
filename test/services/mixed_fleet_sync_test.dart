/// A Medora 0.3.0 phone still syncing next to 0.4.0 devices, against the
/// migrated server. The 0.3.0 phone is played by the server core itself:
/// whole-row upserts with no write id, and a pull that asks for
/// `updated_at` newer than its cursor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
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

  /// What a 0.3.0 phone whose cursor is [cursor] would pull.
  List<String> legacyPull(String table, DateTime cursor) => [
    for (final r in h.core.rowsOf(table).values)
      if (DateTime.parse(r['updated_at'] as String).isAfter(cursor))
        r['id'] as String,
  ];

  setUp(() async {
    await setUpTestDatabase();
    h = TwoDevices(transport: transport);
    h.clock = DateTime.utc(2026, 3, 2, 9);
    await h.a.run(
      (_) => h.a.medications.addMedication(
        const Medication(id: 'm1', name: 'Ibuprofen', quantity: 10),
      ),
    );
    h.clock = DateTime.utc(2026, 3, 5, 8);
  });
  tearDown(() => h.dispose());

  test('a 0.3.0 edit of another field is kept next to a 0.4.0 edit', () async {
    h.a.online = false;
    await h.a.run((_) async {
      final m = (await h.a.medications.getMedicationById('m1')).dataOrNull!;
      await h.a.medications.updateMedication(m.copyWith(name: 'Ibuprofen 400'));
    });
    h.clock = DateTime.utc(2026, 3, 5, 8, 30);
    final legacy = MedicationModel.fromJson(
      h.core.rowsOf('medications')['m1']!,
    ).toJson()..['notes'] = 'after food';
    h.core.legacyUpsert('medications', legacy);
    h.a.online = true;
    h.clock = DateTime.utc(2026, 3, 5, 9);
    await h.a.sync();
    final server = h.core.rowsOf('medications')['m1']!;
    expect([server['name'], server['notes']], ['Ibuprofen 400', 'after food']);
    final row = await h.a.row('medications', 'm1');
    expect(
      [row['name'], row['notes'], row['sync_status']],
      ['Ibuprofen 400', 'after food', 'synced'],
    );
  });

  test('an automatic "missed" is invisible to a 0.3.0 cursor and loses to '
      'its later take', () async {
    // A dose generated long ago, pulled by A; the 0.3.0 phone has it too.
    h.core.insertIfAbsent('treatments', [
      {
        'id': 't1',
        'user_id': 'user-a',
        'name': 'Flu',
        'start_date': '2026-03-01',
        'is_active': true,
        'updated_at': '2026-03-01T08:00:00.000Z',
      },
    ]);
    h.core.insertIfAbsent('prescriptions', [
      {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1',
        'start_time': '2026-03-01T08:00:00',
        'duration_days': 1,
        'updated_at': '2026-03-01T08:00:00.000Z',
      },
    ]);
    h.core.insertIfAbsent('dose_logs', [
      DoseLogModel(
        id: 'd1',
        prescriptionId: 'p1',
        scheduledTime: DateTime.utc(2026, 3, 1, 7),
        updatedAt: DateTime.utc(1970),
      ).toJson(),
    ]);
    await h.a.sync();
    final legacyCursor = DateTime.utc(2026, 3, 5, 7);

    // A's start marks the overdue dose missed and sends it.
    await h.a.run(
      (_) => h.a.doses.markOverduePendingAsMissed(DateTime.utc(2026, 3, 4)),
    );
    expect(h.core.rowsOf('dose_logs')['d1']!['status'], 'missed');
    expect(legacyPull('dose_logs', legacyCursor), isEmpty);

    // The 0.3.0 phone takes it: its stale check sees no newer server copy.
    h.clock = DateTime.utc(2026, 3, 5, 10);
    final legacy = DoseLogModel.fromJson(h.core.rowsOf('dose_logs')['d1']!);
    final serverStamp = DateTime.parse(
      h.core.rowsOf('dose_logs')['d1']!['updated_at'] as String,
    );
    final takeAt = DateTime.utc(2026, 3, 5, 9, 55);
    expect(serverStamp.isAfter(takeAt), isFalse);
    h.core.legacyUpsert(
      'dose_logs',
      DoseLogModel(
        id: legacy.id,
        prescriptionId: legacy.prescriptionId,
        scheduledTime: legacy.scheduledTime,
        status: DoseStatus.taken,
        takenTime: takeAt,
        updatedAt: takeAt,
      ).toJson(),
    );
    await h.a.sync();
    expect((await h.a.row('dose_logs', 'd1'))['status'], 'taken');
  });

  test(
    'a row created offline on 0.4.0 reaches a 0.3.0 cursor that moved on',
    () async {
      h.a.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 8);
      await h.a.run(
        (_) => h.a.treatments.addTreatment(
          Treatment(id: 't2', name: 'Cold', startDate: DateTime(2026, 3, 5)),
        ),
      );
      final legacyCursor = DateTime.utc(2026, 3, 5, 9);
      h.clock = DateTime.utc(2026, 3, 5, 10);
      h.a.online = true;
      await h.a.sync();
      expect(legacyPull('treatments', legacyCursor), contains('t2'));
    },
  );

  test('known limitation: a 0.3.0 absolute quantity replaces a stock change '
      'that landed before it', () async {
    await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    final legacy = MedicationModel.fromJson(
      h.core.rowsOf('medications')['m1']!,
    ).toJson()..['quantity'] = 10;
    h.clock = DateTime.utc(2026, 3, 5, 9);
    h.core.legacyUpsert('medications', legacy);
    await h.a.sync();
    expect((await h.a.row('medications', 'm1'))['quantity'], 10);
  });
}
