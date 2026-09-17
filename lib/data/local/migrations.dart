/// Medora - Local schema migrations.
///
/// Add a new [Migration] with the next version number at the END of
/// [kMigrations] and bump [kSchemaVersion]. Never edit a migration that has
/// shipped in a release.
library;

import 'package:medora/data/local/edit_time.dart';
import 'package:sqflite/sqflite.dart';

class Migration {
  const Migration(this.version, this.run);

  final int version;
  final Future<void> Function(Database db) run;
}

/// Current schema version. Must equal the last entry of [kMigrations].
const int kSchemaVersion = 16;

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
  // v15: sick leave (Krankenstand) on an illness episode: the days unable to
  // work, which need not equal the illness period, plus the certificate
  // number and the doctor. All nullable — an ordinary therapy leaves them
  // empty. No index: the list screen loads every treatment and filters in
  // Dart.
  Migration(15, (db) async {
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_from TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_to TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN sick_leave_ref TEXT');
    await db.execute('ALTER TABLE treatments ADD COLUMN doctor TEXT');
  }),
  // v16: sync v2 (supabase/migrations/20260918000000_sync_v2.sql). Each
  // synced row keeps when its last change was made here (`edited_at`, 1970
  // for a change the app made on its own), when each of its columns was
  // last changed (`field_edited_at`, JSON; NULL until a column changes: the
  // row's `edited_at` stands for all of them), the server copy it was last in
  // step with (`sync_version`, `sync_base`, the base of every merge) and
  // the write attempt whose answer never came (`sync_write_id`). A dose the
  // app drops from a changed schedule is deleted on the server only while
  // it is still pending (`delete_guard`). Stock changes wait in their own
  // outbox, as changes, never as totals, in the order they were made
  // (`seq`: the device clock can repeat a millisecond or step back).
  Migration(16, (db) async {
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      await db.execute('ALTER TABLE $table ADD COLUMN edited_at TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN field_edited_at TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_version INTEGER');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_base TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_write_id TEXT');
      await _backfillEditedAt(db, table, DateTime.now());
    }
    await db.execute('ALTER TABLE dose_logs ADD COLUMN delete_guard TEXT');
    await db.execute('''
      CREATE TABLE stock_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op_id TEXT NOT NULL UNIQUE,
        medication_id TEXT NOT NULL
          REFERENCES medications(id) ON DELETE CASCADE,
        delta INTEGER,
        set_to INTEGER,
        created_at TEXT NOT NULL,
        CHECK ((delta IS NULL) <> (set_to IS NULL))
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_local_stock_outbox_med '
      'ON stock_outbox(medication_id, seq)',
    );
  }),
];

/// Migration 16's backfill: a change still waiting to be pushed was made
/// when it was stamped, so its `edited_at` is its `updated_at` in UTC.
///
/// Done in Dart, not SQL: 0.3.0 wrote local stamps as naive local text,
/// and only a parse in the zone they were written in gives the instant,
/// with the offset in force on that day (a stamp from before the October
/// change keeps summer time). A stamp that reads as later than [now]
/// (written further east, or before the clock stepped back) is capped at
/// [now]; one that does not parse is left NULL, and the sync reads
/// `updated_at` instead. A `pending_delete` row gets its `updated_at`,
/// not its `deleted_at`: a person's delete wins whatever its time.
Future<void> _backfillEditedAt(Database db, String table, DateTime now) async {
  final rows = await db.query(
    table,
    columns: ['id', 'updated_at'],
    where: "sync_status != 'synced' AND updated_at IS NOT NULL",
  );
  final batch = db.batch();
  for (final row in rows) {
    final stamp = DateTime.tryParse(row['updated_at']! as String);
    if (stamp == null) continue;
    batch.update(
      table,
      {'edited_at': editedAtText(stamp, now)},
      where: 'id = ?',
      whereArgs: [row['id']],
    );
  }
  await batch.commit(noResult: true);
}
