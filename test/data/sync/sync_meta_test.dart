import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/person_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';
import 'package:medora/data/models/rx_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';

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
    'persons': PersonLocalDatasource.rowOf(
      PersonModel(
        id: 'pe1',
        name: 'Anna',
        taxCode: 'RSSMRA85T10A562S',
        exemptions: const ['esente'],
        notes: 'allergic to penicillin',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'rx': RxLocalDatasource.rowOf(
      RxModel(
        id: 'r1',
        personId: 'pe1',
        treatmentId: 't1',
        kind: RxKind.ssn,
        nre: '0410A1234567890',
        issuedOn: DateTime(2026, 3, 20),
        validUntil: DateTime(2026, 4, 19),
        doctor: 'Dr. Rossi',
        priority: RxPriority.b,
        items: const [RxItem(id: 'i1', description: 'Brufen')],
        notes: 'take with food',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'rx_dispensings': RxDispensingLocalDatasource.rowOf(
      RxDispensingModel(
        id: 'rd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 3, 21),
        pharmacy: 'Farmacia Centrale',
        updatedAt: editedHere,
      ),
      SyncStatus.pendingCreate,
    ),
    'attachments': AttachmentLocalDatasource.rowOf(
      AttachmentModel(
        id: 'att1',
        ownerKind: AttachmentOwnerKind.rx,
        ownerId: 'r1',
        kind: AttachmentKind.photo,
        mime: 'image/jpeg',
        sizeBytes: 12345,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        originalName: 'scan.jpg',
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

    test('keeps the base\'s column times with the base, apart from it', () {
      final times = FieldTimes({
        'name': FieldTime(DateTime.utc(2026, 3, 5, 9)),
        'notes': FieldTime.automaticChange,
      }, rowTime: DateTime.utc(2026, 3, 5, 8));
      final values = syncMetaValues(
        version: 2,
        base: const {'id': 'x', 'name': 'Base'},
        baseTimes: times,
      );
      final meta = LocalSyncMeta.fromRow(values);
      expect(meta.base, {'id': 'x', 'name': 'Base'});
      expect(meta.baseTimes!.entries, times.entries);
      expect(meta.baseTimes!.rowTime, DateTime.utc(2026, 3, 5, 8));
      // An empty map keeps the row time that stands for every column.
      final empty = LocalSyncMeta.fromRow(
        syncMetaValues(
          version: 1,
          base: const {'id': 'x'},
          baseTimes: FieldTimes(const {}, rowTime: DateTime.utc(1970)),
        ),
      );
      expect(empty.baseTimes!.of('name'), FieldTime.automaticChange);
      // A base stored without times has none.
      expect(
        LocalSyncMeta.fromRow(
          syncMetaValues(version: 1, base: const {'id': 'x'}),
        ).baseTimes,
        isNull,
      );
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
