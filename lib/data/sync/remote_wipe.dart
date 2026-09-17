/// Medora - "Delete all data" made on another device (sync v2).
///
/// `medora_delete_all_data` removes the account's rows on the server and
/// records when it ran. A device that learns of it removes what it holds
/// from before that moment ([removeDataFromBefore]); the cycle then pulls
/// whatever the server has.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:sqflite/sqflite.dart';

/// What [removeDataFromBefore] removed.
class RemovedData {
  const RemovedData({required this.rows, required this.photos});

  /// How many rows of the synced tables went, children taken with their
  /// parents included.
  final int rows;

  /// The stored photo names of removed medications that no medication kept
  /// here still uses.
  final List<String> photos;
}

/// Removes every medication, treatment, prescription and dose this device
/// created before [wipedAt] (by their `created_at`; a row without one
/// counts as older), whatever its sync state: synced copies, and changes
/// still waiting to be sent, which belong to rows the person deleted
/// everywhere. A row created after [wipedAt] stays, with its sync state:
/// it is new data. Children go with a removed parent, and stock changes
/// with their medication (the local foreign keys cascade). Families are
/// not part of "delete all data" and stay.
///
/// The device's clock decides "after", so a row made within the clock's
/// error of the wipe can land on the wrong side.
Future<RemovedData> removeDataFromBefore(
  DatabaseExecutor db,
  DateTime wipedAt,
) async {
  const tables = ['medications', 'treatments', 'prescriptions', 'dose_logs'];
  Future<int> count() async {
    var n = 0;
    for (final table in tables) {
      n +=
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $table'),
          ) ??
          0;
    }
    return n;
  }

  final before = await count();
  final photos = <String>{};
  for (final table in tables) {
    final rows = await db.query(
      table,
      columns: ['id', 'created_at', if (table == 'medications') 'image_path'],
    );
    for (final row in rows) {
      final raw = row['created_at'];
      final created = raw is String ? DateTime.tryParse(raw) : null;
      if (created != null && created.isAfter(wipedAt)) continue;
      final image = row['image_path'];
      if (image is String && image.isNotEmpty) photos.add(image);
      await db.delete(table, where: 'id = ?', whereArgs: [row['id']]);
    }
  }
  final kept = await db.query('medications', columns: ['image_path']);
  photos.removeAll(kept.map((r) => r['image_path']));
  return RemovedData(
    rows: before - await count(),
    photos: photos.toList()..sort(),
  );
}

/// [removeDataFromBefore] in one transaction of the app's database.
Future<RemovedData> removeLocalDataFromBefore(DateTime wipedAt) async {
  final db = await AppDatabase.instance.database;
  return db.transaction((txn) => removeDataFromBefore(txn, wipedAt));
}
