import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/domain/entities/dose_log.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  // Stamps as the app makes them: local wall-clock times.
  final editedHere = DateTime.utc(2026, 3, 29, 1, 5).toLocal();
  final doseTime = DateTime.utc(2026, 3, 29, 0, 30).toLocal();

  final rows = <String, Map<String, dynamic>>{
    'medications': MedicationLocalDatasource.rowOf(
      MedicationModel(
        id: 'm1',
        name: 'Ibuprofen 400',
        activeIngredients: const ['ibuprofen'],
        symptoms: const ['pain', 'fever'],
        patientTags: const ['Anna'],
        purchaseDate: DateTime(2026, 3, 2),
        expiryDate: DateTime(2027, 10, 31),
        quantity: 18,
        quantityUnit: 'tablets',
        barcode: '8001234567890',
        ean: '8001234567890',
        imagePath: 'photo_m1.jpg',
        notes: 'after food',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'treatments': TreatmentLocalDatasource.rowOf(
      TreatmentModel(
        id: 't1',
        name: 'Sinusitis',
        patientTags: const ['Anna'],
        symptomTags: const ['headache'],
        startDate: DateTime(2026, 3, 28),
        endDate: DateTime(2026, 3, 29),
        isActive: false,
        sickLeaveFrom: DateTime(2026, 3, 28),
        sickLeaveTo: DateTime(2026, 3, 29),
        sickLeaveRef: 'CERT-B',
        doctor: 'Dr. Rossi',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'prescriptions': PrescriptionLocalDatasource.rowOf(
      PrescriptionModel(
        id: 'p1',
        treatmentId: 't1',
        medicationId: 'm1',
        dosage: '1 tablet',
        dosageAmount: 1.5,
        dosageUnit: 'tablet',
        durationDays: 5,
        startTime: DateTime(2026, 3, 28, 8),
        scheduleType: 'fixed_times',
        scheduleTimes: const ['08:00', '20:00'],
        notes: 'with water',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'dose_logs': DoseLogLocalDatasource.rowOf(
      DoseLogModel(
        id: 'd1',
        prescriptionId: 'p1',
        scheduledTime: doseTime,
        takenTime: doseTime.add(const Duration(minutes: 7)),
        status: DoseStatus.taken,
        notes: 'late',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
  };

  for (final table in syncedTables) {
    test('$table: a row made here and the server copy of it have the same '
        'content, and a pulled copy reads back the same', () async {
      final db = await AppDatabase.instance.database;
      // The row and its parents.
      for (final t in syncedTables.take(syncedTables.indexOf(table) + 1)) {
        await db.insert(t, rows[t]!);
      }
      final local = (await db.query(table)).single;
      final core = FakeServerCore(() => DateTime.utc(2026, 3, 29, 2));
      final wire = localWire(table, local, userId: 'u');
      core.insertIfAbsent(table, [
        {...wire, 'write_id': 'w1', 'edited_at': '2026-03-29T01:05:00.000Z'},
      ]);
      final server = core.fetch(table, local['id']! as String)!;
      final policy = mergePolicyOf(table);

      final canonical = canonicalWire(table, server);
      expect(changedColumns(canonical, wire, policy), isEmpty);
      expect(changedColumns(wire, canonical, policy), isEmpty);

      // The same row pulled onto another device.
      await db.delete(table);
      await db.insert(table, localRowOf(table, server, SyncStatus.synced));
      final pulled = (await db.query(table)).single;
      expect(sameContent(localWire(table, pulled), canonical, policy), isTrue);
    });
  }

  group('LocalSyncMeta', () {
    test('reads a local wall-clock and a UTC edit time as instants', () {
      final instant = DateTime.utc(2026, 10, 25, 0, 40);
      for (final raw in [
        instant.toLocal().toIso8601String(),
        instant.toIso8601String(),
        '2026-10-25T00:40:00+00:00',
      ]) {
        final meta = LocalSyncMeta.fromRow({'edited_at': raw});
        expect(meta.editedAt!.isAtSameMomentAs(instant), isTrue, reason: raw);
      }
    });

    test('round-trips its values', () {
      final values = syncMetaValues(
        version: 7,
        base: const {'id': 'x', 'name': 'Base'},
        writeId: 'w9',
        editedAt: DateTime.utc(2026, 3, 29, 1, 5).toLocal(),
      );
      expect(values['edited_at'], '2026-03-29T01:05:00.000Z');
      final meta = LocalSyncMeta.fromRow(values);
      expect(
        [meta.version, meta.base, meta.writeId],
        [
          7,
          {'id': 'x', 'name': 'Base'},
          'w9',
        ],
      );
      expect(
        syncMetaValues(version: null, base: null).containsKey('edited_at'),
        isFalse,
      );
      expect(clearedSyncMeta.keys, [
        'sync_version',
        'sync_base',
        'sync_write_id',
      ]);
      expect(syncMetaColumnNames, [
        'edited_at',
        'field_edited_at',
        ...clearedSyncMeta.keys,
      ]);
    });
  });
}
