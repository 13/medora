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
const int kSchemaVersion = 11;

final List<Migration> kMigrations = [
  // v11: tombstone column for sync (spec §4.3). photo_file arrives with Phase 1.
  Migration(11, (db) async {
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    }
  }),
];
