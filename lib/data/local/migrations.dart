/// Medora - Local schema migrations.
///
/// Add a new [Migration] with the next version number at the END of
/// [kMigrations] and bump [kSchemaVersion]. Never edit an existing migration.
library;

import 'package:sqflite/sqflite.dart';

class Migration {
  const Migration(this.version, this.run);

  final int version;
  final Future<void> Function(Database db) run;
}

/// Current schema version. Must equal the last entry of [kMigrations].
const int kSchemaVersion = 14;

final List<Migration> kMigrations = [
  // v11: tombstone column for sync (spec §4.3). Photos keep using image_path
  // (bare filename, see v12) rather than a separate photo_file column.
  Migration(11, (db) async {
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    }
  }),
  // v12: photos are referenced by bare filename (spec §4.3 / audit F10).
  Migration(12, (db) async {
    final rows = await db.query(
      'medications',
      columns: ['id', 'image_path'],
      where: "image_path IS NOT NULL AND image_path LIKE '%/%'",
    );
    for (final row in rows) {
      final path = row['image_path'] as String;
      final name = path.substring(path.lastIndexOf('/') + 1);
      await db.update(
        'medications',
        {'image_path': name},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }),
  // v13: dose timestamps are stored as naive local ISO strings so that
  // string range comparisons match local day boundaries (Phase 1 review).
  // Converts with the device's current time zone; rows written in another
  // zone or across a DST change may shift.
  Migration(13, (db) async {
    for (final column in [
      'scheduled_time',
      'taken_time',
      'updated_at',
      'created_at',
    ]) {
      final rows = await db.query(
        'dose_logs',
        columns: ['id', column],
        where: "$column LIKE '%Z'",
      );
      for (final row in rows) {
        final local = DateTime.parse(
          row[column] as String,
        ).toLocal().toIso8601String();
        await db.update(
          'dose_logs',
          {column: local},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
  }),
  // v14: the EAN barcode of the pack, next to the label code in `barcode`.
  // A scan that reads both remembers both, and a later scan of either finds
  // the medication.
  Migration(14, (db) async {
    await db.execute('ALTER TABLE medications ADD COLUMN ean TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_med_ean ON medications(ean)',
    );
  }),
];
