/// Medora - Full backup of the local database, the medication photos and
/// the attachment files.
///
/// The backup is a single JSON file so that it can travel through any share
/// sheet, mail attachment or cloud drive and still be read back by a later
/// build. It is deliberately *not* a copy of the SQLite file: the envelope is
/// versioned, the rows are plain maps, and a restore goes through the current
/// schema instead of replacing it.
///
/// Rows are stored exactly as the database holds them (naive-local ISO
/// timestamps, tombstones included) minus the local sync bookkeeping
/// ([BackupService.localOnlyColumns]), which is re-stamped on restore.
/// `edited_at` and `field_edited_at` stay: a restored row keeps the times
/// its last changes were made.
///
/// Attachment files travel under `attachmentFiles` (file name → base64),
/// with the photos: leaving the photos out leaves them out too, and a
/// restored attachment without its file is downloaded again when opened.
library;

import 'dart:convert';
import 'dart:io';

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/data/local/migrations.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Why a backup file could not be read or applied.
enum BackupErrorKind {
  /// The file is not JSON, or not a Medora backup at all.
  notABackup,

  /// Written by a newer app that uses a newer envelope format.
  newerFormat,

  /// Written against a newer database schema than this build knows.
  newerSchema,

  /// A Medora backup, but its contents cannot be applied.
  corrupt,

  /// The file could not be read or written.
  io,
}

class BackupException implements Exception {
  const BackupException(this.kind, [this.details]);

  final BackupErrorKind kind;
  final String? details;

  @override
  String toString() =>
      'BackupException(${kind.name}${details == null ? '' : ': $details'})';
}

/// What a backup file contains - shown before a restore is confirmed.
class BackupManifest {
  const BackupManifest({
    required this.version,
    required this.schemaVersion,
    required this.createdAt,
    required this.appVersion,
    required this.rowCounts,
    required this.photoCount,
    this.attachmentFileCount = 0,
  });

  final int version;
  final int schemaVersion;
  final DateTime createdAt;
  final String appVersion;
  final Map<String, int> rowCounts;
  final int photoCount;

  /// Attachment files carried with the photos.
  final int attachmentFileCount;

  int get totalRows => rowCounts.values.fold(0, (sum, n) => sum + n);
}

/// How a backup is applied to the data already on the device.
enum RestoreMode {
  /// Everything local is removed first; the backup becomes the whole database.
  replace,

  /// Rows are merged by id, keeping whichever copy was updated last.
  merge,
}

class BackupService {
  BackupService({
    required this._database,
    required this._photos,
    required this._attachments,
    required this._now,
    required this._appVersion,
    String Function()? newOpId,
  }) : _newOpId = newOpId ?? const Uuid().v4;

  final AppDatabase _database;
  final PhotoStorage _photos;
  final AttachmentFiles _attachments;
  final DateTime Function() _now;
  final String _appVersion;

  /// Names a restored quantity's stock change (a uuid: the server's ledger
  /// key).
  final String Function() _newOpId;

  /// Envelope marker; anything else is not a Medora backup.
  static const format = 'medora-backup';

  /// Envelope version. Bump only for a breaking change of the file layout.
  static const formatVersion = 1;

  /// The tables carried by a backup.
  static const tables = [
    'medications',
    'treatments',
    'prescriptions',
    'dose_logs',
    'families',
    'family_members',
    'persons',
    'rx',
    'rx_dispensings',
    'attachments',
  ];

  /// Insert order that satisfies every foreign key.
  static const _insertOrder = [
    'families',
    'family_members',
    'medications',
    'treatments',
    'prescriptions',
    'dose_logs',
    'persons',
    'rx',
    'rx_dispensings',
    'attachments',
  ];

  /// Tables a restore never stamps `pending_update`.
  ///
  /// A restore can carry every member of a family, but the cloud only ever
  /// accepts the row of the signed-in user: RLS rejects a push of anyone
  /// else's `family_members` row, and a rejected row stays pending and is
  /// retried until the sync backs off for good. The user's own member row is
  /// marked for upload by `LocalUploadMarker.markAllForUpload` after the
  /// restore instead.
  static const _neverPending = {'family_members'};

  /// Tables whose rows carry an `updated_at` to compare during a merge.
  static const _versioned = {
    'medications',
    'treatments',
    'prescriptions',
    'dose_logs',
    'persons',
    'rx',
    'rx_dispensings',
    'attachments',
  };

  /// Columns that describe this device's sync state, never carried by a
  /// backup: another device, or this one later, is in another state.
  static const localOnlyColumns = {
    'sync_status',
    'sync_version',
    'sync_base',
    'sync_write_id',
    'delete_guard',
  };

  /// Photo payload above which the UI defaults to leaving the photos out:
  /// the export holds the whole envelope in memory before it is written.
  static const largePhotoBytes = 150 * 1024 * 1024;

  /// How many bytes the photos and attachment files would add to a
  /// backup, before base64 (which grows them by about a third). Cheap: it
  /// only stats the files.
  Future<int> estimatePhotoBytes() async {
    try {
      var total = 0;
      for (final file in [
        ...await _photos.listAll(),
        ...await _attachmentFiles(),
      ]) {
        total += await file.length();
      }
      return total;
    } on FileSystemException {
      return 0;
    }
  }

  /// How many photos and attachment files a backup would carry.
  Future<int> countPhotos() async {
    try {
      return (await _photos.listAll()).length +
          (await _attachmentFiles()).length;
    } on FileSystemException {
      return 0;
    }
  }

  /// The files of live attachments that are on this device. A deleted
  /// attachment's file, one not downloaded yet, a stray file and a write
  /// still running are not part of a backup.
  Future<List<File>> _attachmentFiles() async {
    final db = await _database.database;
    final rows = await db.query(
      'attachments',
      columns: ['id', 'kind'],
      where: 'deleted_at IS NULL',
      orderBy: 'id',
    );
    final on = (await _attachments.listNames()).toSet();
    final files = <File>[];
    for (final row in rows) {
      final kind = row['kind'] == 'pdf' ? 'pdf' : 'jpg';
      final name = '${row['id']}.$kind';
      if (!on.contains(name)) continue;
      files.add(await _attachments.fileNamed(name));
    }
    return files;
  }

  /// Writes `medora-backup-<yyyyMMdd-HHmmss>.json` into [dir] and returns it.
  ///
  /// The envelope is encoded in one go, so a backup costs roughly the size of
  /// the finished file in memory; [includePhotos] is what keeps that bounded
  /// on a photo-heavy cabinet.
  Future<File> exportToFile(Directory dir, {bool includePhotos = true}) async {
    try {
      final db = await _database.database;
      final data = <String, List<Map<String, Object?>>>{};
      for (final table in tables) {
        final rows = await db.query(table);
        data[table] = [
          for (final row in rows)
            {
              for (final entry in row.entries)
                if (!localOnlyColumns.contains(entry.key))
                  entry.key: entry.value,
            },
        ];
      }

      final photos = <String, String>{};
      if (includePhotos) {
        for (final file in await _photos.listAll()) {
          photos[p.basename(file.path)] = base64Encode(
            await file.readAsBytes(),
          );
        }
      }
      final attachmentFiles = <String, String>{};
      if (includePhotos) {
        for (final file in await _attachmentFiles()) {
          attachmentFiles[p.basename(file.path)] = base64Encode(
            await file.readAsBytes(),
          );
        }
      }

      final stamp = _now();
      final envelope = {
        'format': format,
        'version': formatVersion,
        'schemaVersion': kSchemaVersion,
        'createdAt': stamp.toUtc().toIso8601String(),
        'appVersion': _appVersion,
        'tables': data,
        'photos': photos,
        'attachmentFiles': attachmentFiles,
      };

      if (!dir.existsSync()) await dir.create(recursive: true);
      final file = File(
        p.join(dir.path, 'medora-backup-${_stamp(stamp)}.json'),
      );
      await file.writeAsString(jsonEncode(envelope), flush: true);
      return file;
    } on BackupException {
      rethrow;
    } on FileSystemException catch (e) {
      throw BackupException(BackupErrorKind.io, e.message);
    } on DatabaseException catch (e) {
      throw BackupException(BackupErrorKind.corrupt, e.toString());
    }
  }

  /// Validates [file] and reports what it holds, without touching the device.
  Future<BackupManifest> inspect(File file) async =>
      (await _read(file)).manifest;

  /// Applies [file] to the local database, photo folder and attachment
  /// folder.
  ///
  /// The database part runs inside one transaction: a backup that cannot be
  /// applied in full leaves the device exactly as it was. Photos and
  /// attachment files are written afterwards (files have no transaction)
  /// and never removed here - a photo that nothing references costs a few
  /// kilobytes, a missing one loses data. An attachment file no row points
  /// at goes with the transfer's next sweep.
  ///
  /// [markPending] re-stamps every restored row as `pending_update` so a
  /// cloud-mode device uploads the restored data on the next sync cycle -
  /// except `family_members` (see [_neverPending]), which stays `synced`.
  /// Nothing about the server copy is known any more, so the next push
  /// merges by edit time. A push never sends a stock, so each medication the
  /// restore writes also queues its quantity as a count (a stock change the
  /// server applies once, after the changes this device still holds for
  /// it); a medication the server lacks is created with that quantity
  /// instead, and the count is dropped then.
  Future<BackupManifest> restore(
    File file, {
    required RestoreMode mode,
    bool markPending = false,
  }) async {
    final backup = await _read(file);
    final status = markPending ? SyncStatus.pendingUpdate : SyncStatus.synced;
    final db = await _database.database;

    try {
      await db.transaction((txn) async {
        if (mode == RestoreMode.replace) {
          for (final table in _insertOrder.reversed) {
            await txn.delete(table);
          }
        }
        for (final table in _insertOrder) {
          final rows = backup.rows[table] ?? const <Map<String, Object?>>[];
          final tableStatus = _neverPending.contains(table)
              ? SyncStatus.synced
              : status;
          for (final row in rows) {
            final written = await _applyRow(txn, table, row, mode, tableStatus);
            final id = row['id'];
            if (written &&
                markPending &&
                table == 'medications' &&
                id is String &&
                row['deleted_at'] == null) {
              await StockOutboxLocalDatasource.enqueue(
                txn,
                StockOp(
                  opId: _newOpId(),
                  medicationId: id,
                  setTo: (row['quantity'] as num?)?.toInt() ?? 0,
                  createdAt: _now(),
                ),
              );
            }
          }
        }
      });
    } on DatabaseException catch (e) {
      throw BackupException(BackupErrorKind.corrupt, e.toString());
    }

    for (final entry in backup.photos.entries) {
      try {
        await _photos.writeBytes(entry.key, base64Decode(entry.value));
      } on FormatException catch (e) {
        throw BackupException(BackupErrorKind.corrupt, e.message);
      } on FileSystemException catch (e) {
        throw BackupException(BackupErrorKind.io, e.message);
      }
    }
    for (final entry in backup.attachmentFiles.entries) {
      try {
        await _attachments.write(entry.key, base64Decode(entry.value));
      } on FormatException catch (e) {
        throw BackupException(BackupErrorKind.corrupt, e.message);
      } on FileSystemException catch (e) {
        throw BackupException(BackupErrorKind.io, e.message);
      }
    }

    return backup.manifest;
  }

  /// Writes one backed-up row; returns whether it was written.
  ///
  /// In [RestoreMode.replace] the tables were emptied first, so every row is
  /// a plain insert. In [RestoreMode.merge] a row whose id is not on the
  /// device is inserted; for an id that already exists only the tables in
  /// [_versioned] are compared, and the backup wins only when its
  /// `updated_at` is strictly newer - a tie, a missing timestamp, or a row of
  /// `families`/`family_members` (which carry no `updated_at`) keeps whatever
  /// the device already holds. Stamps are compared as instants: the device
  /// holds both naive-local and UTC stamps.
  Future<bool> _applyRow(
    Transaction txn,
    String table,
    Map<String, Object?> row,
    RestoreMode mode,
    String status,
  ) async {
    final values = {
      ...row,
      'sync_status': status,
      if (_versioned.contains(table)) ...{
        // A schema 15 row has no edit times: stored as unknown, never left
        // at the device's values for content that came from the backup.
        'edited_at': row['edited_at'],
        'field_edited_at': row['field_edited_at'],
        'sync_version': null,
        'sync_base': null,
        'sync_write_id': null,
      },
      if (table == 'dose_logs') 'delete_guard': null,
    };
    final id = row['id'];
    if (mode == RestoreMode.replace || id == null) {
      await txn.insert(table, values);
      return true;
    }

    final existing = await txn.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await txn.insert(table, values);
      return true;
    }
    if (!_versioned.contains(table)) return false;

    final mine = _instant(existing.single['updated_at']);
    final theirs = _instant(row['updated_at']);
    if (mine != null && (theirs == null || !theirs.isAfter(mine))) {
      return false;
    }
    await txn.update(table, values, where: 'id = ?', whereArgs: [id]);
    return true;
  }

  static DateTime? _instant(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  Future<_Backup> _read(File file) async {
    final String content;
    try {
      content = await file.readAsString();
    } on FileSystemException catch (e) {
      throw BackupException(BackupErrorKind.io, e.message);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (e) {
      throw BackupException(BackupErrorKind.notABackup, e.message);
    }
    if (decoded is! Map<String, Object?> || decoded['format'] != format) {
      throw const BackupException(BackupErrorKind.notABackup);
    }

    final version = decoded['version'];
    final schemaVersion = decoded['schemaVersion'];
    if (version is! int || schemaVersion is! int) {
      throw const BackupException(BackupErrorKind.corrupt, 'missing version');
    }
    if (version > formatVersion) {
      throw const BackupException(BackupErrorKind.newerFormat);
    }
    if (schemaVersion > kSchemaVersion) {
      throw const BackupException(BackupErrorKind.newerSchema);
    }

    final rows = <String, List<Map<String, Object?>>>{};
    final rawTables = decoded['tables'];
    if (rawTables is! Map<String, Object?>) {
      throw const BackupException(BackupErrorKind.corrupt, 'no tables');
    }
    for (final table in tables) {
      final list = rawTables[table] ?? const <Object?>[];
      if (list is! List) {
        throw BackupException(BackupErrorKind.corrupt, table);
      }
      final parsed = <Map<String, Object?>>[];
      for (final row in list) {
        if (row is! Map<String, Object?>) {
          throw BackupException(BackupErrorKind.corrupt, table);
        }
        parsed.add(
          {...row}..removeWhere((k, _) => localOnlyColumns.contains(k)),
        );
      }
      rows[table] = parsed;
    }

    final photos = <String, String>{};
    final rawPhotos = decoded['photos'];
    if (rawPhotos is Map<String, Object?>) {
      for (final entry in rawPhotos.entries) {
        final value = entry.value;
        if (value is! String) {
          throw BackupException(BackupErrorKind.corrupt, entry.key);
        }
        photos[entry.key] = value;
      }
    }

    // The only file names a backup may carry: `<id>.<ext>` of its own
    // attachment rows, the extension matching the row's kind. Anything else
    // (an empty name, `.`, `..`, a file without a row, another type) makes
    // the backup corrupt before the database is touched.
    final expectedFileNames = <String>{
      for (final row in rows['attachments'] ?? const <Map<String, Object?>>[])
        if (row['id'] case final String id when id.isNotEmpty)
          for (final kind in AttachmentKind.values)
            if (row['kind'] == kind.wire) '$id.${kind.extension}',
    };
    final attachmentFiles = <String, String>{};
    final rawAttachmentFiles = decoded['attachmentFiles'];
    if (rawAttachmentFiles is Map<String, Object?>) {
      for (final entry in rawAttachmentFiles.entries) {
        final value = entry.value;
        // A bare file name too: nothing may be written outside the folder.
        if (value is! String ||
            !expectedFileNames.contains(entry.key) ||
            p.basename(entry.key) != entry.key) {
          throw BackupException(BackupErrorKind.corrupt, entry.key);
        }
        attachmentFiles[entry.key] = value;
      }
    }

    final createdAt = DateTime.tryParse('${decoded['createdAt']}');
    if (createdAt == null) {
      throw const BackupException(BackupErrorKind.corrupt, 'no createdAt');
    }

    return _Backup(
      manifest: BackupManifest(
        version: version,
        schemaVersion: schemaVersion,
        createdAt: createdAt.toUtc(),
        appVersion: '${decoded['appVersion'] ?? ''}',
        rowCounts: {
          for (final entry in rows.entries) entry.key: entry.value.length,
        },
        photoCount: photos.length,
        attachmentFileCount: attachmentFiles.length,
      ),
      rows: rows,
      photos: photos,
      attachmentFiles: attachmentFiles,
    );
  }

  static String _stamp(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }
}

class _Backup {
  const _Backup({
    required this.manifest,
    required this.rows,
    required this.photos,
    required this.attachmentFiles,
  });

  final BackupManifest manifest;
  final Map<String, List<Map<String, Object?>>> rows;
  final Map<String, String> photos;
  final Map<String, String> attachmentFiles;
}
