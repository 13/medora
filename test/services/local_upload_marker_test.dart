import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('flips every synced row to pending_update and clears cursors', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final cursors = SyncCursorStore.inMemory();
    await cursors.setLastPullAt('medications', DateTime.utc(2026));

    final marker = LocalUploadMarker(database: AppDatabase.instance, cursors: cursors);
    final n = await marker.markAllForUpload();

    expect(n, 4);
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      final rows = await db.query(table, columns: ['sync_status']);
      expect(rows.map((r) => r['sync_status']), everyElement(SyncStatus.pendingUpdate), reason: table);
    }
    expect(await cursors.lastPullAt('medications'), isNull);
  });

  test('pending_delete rows are left alone', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await db.update('medications', {'sync_status': SyncStatus.pendingDelete}, where: 'id = ?', whereArgs: [seeded.medicationId]);
    final marker = LocalUploadMarker(database: AppDatabase.instance, cursors: SyncCursorStore.inMemory());
    await marker.markAllForUpload();
    final row = (await db.query('medications', where: 'id = ?', whereArgs: [seeded.medicationId])).single;
    expect(row['sync_status'], SyncStatus.pendingDelete);
  });
}
