/// Medora - Pull and push of one synced table (sync v2).
///
/// The sync cycle (`SyncService`) decides when and in which order; this
/// class does the per-row work for medications, treatments, prescriptions
/// and dose logs: it applies a pulled row (storing it, merging it with a
/// pending local change, or deleting), and pushes one pending row
/// (conditional on the server version it was based on, recognising its own
/// write when an answer was lost). It records nothing about failures: an
/// error propagates to the cycle, which backs the row off.
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite/sqflite.dart';

/// What applying one pulled row did.
enum PullOutcome {
  /// A row new to this device was stored.
  inserted,

  /// The local copy was replaced by the server's.
  replaced,

  /// A pending local change was merged with the server's copy.
  merged,

  /// The local row was deleted (a tombstone).
  deleted,

  /// Nothing changed: a local delete waits to be pushed, the server copy
  /// is one this device already merged, or the row belongs under a parent
  /// deleted here.
  kept,

  /// Not stored: the live row names a parent this device does not hold.
  /// The caller finds out whether that parent is still to come.
  orphaned,
}

class PullApplied {
  const PullApplied(this.outcome, [this.conflicts = const []]);
  final PullOutcome outcome;

  /// Groups both sides changed; see [MergeConflict].
  final List<MergeConflict> conflicts;
}

/// What pushing one row did.
enum PushOutcome {
  /// The row is in step with the server (or gone).
  settled,

  /// The row still has changes for a later cycle: it was edited while the
  /// push ran, or the server moved on twice while this cycle merged.
  pending,
}

class PushResult {
  const PushResult(this.outcome, [this.conflicts = const []]);
  final PushOutcome outcome;
  final List<MergeConflict> conflicts;
}

/// The parents a row of [table] names, as `(parent table, id)`, in
/// foreign-key order. A row of a table with no parent names none.
List<(String, String)> parentsOf(String table, Map<String, Object?> row) {
  (String, String)? parent(String parentTable, String column) =>
      row[column] is String ? (parentTable, row[column]! as String) : null;
  return [
    ...?switch (table) {
      'prescriptions' => [
        parent('treatments', 'treatment_id'),
        parent('medications', 'medication_id'),
      ],
      'dose_logs' => [parent('prescriptions', 'prescription_id')],
      _ => null,
    }?.nonNulls,
  ];
}

/// How the parents a row names stand on this device.
enum _Parents {
  /// Every parent is here and not deleted.
  live,

  /// A parent is deleted here, its delete waiting to be pushed.
  deleted,

  /// A parent is not here at all.
  absent,
}

class TableSync {
  TableSync({
    required this.table,
    required this.remote,
    required this.newWriteId,
    required this.now,
    this.wipeSeen,
  }) : policy = mergePolicyOf(table);

  final String table;
  final SyncTable remote;

  /// A fresh id for a write attempt or a stock change (uuid v4 in the app).
  final String Function() newWriteId;
  final DateTime Function() now;
  final MergePolicy policy;

  /// The "delete all data" generation this device has applied; every
  /// insert sends it ([insertTimes]).
  final int? Function()? wipeSeen;

  /// How many times one push tries again after the server moved on.
  static const maxAttempts = 2;

  Future<Database> get _db => AppDatabase.instance.database;

  // ── Pull ───────────────────────────────────────────────────

  /// Applies the pulled server row [json] (see the design, section 7.2).
  Future<PullApplied> applyPulled(Map<String, dynamic> json) async {
    final db = await _db;
    return db.transaction((txn) => _applyPulled(txn, json));
  }

  Future<PullApplied> _applyPulled(
    Transaction txn,
    Map<String, dynamic> json,
  ) async {
    final id = json['id']! as String;
    final meta = RemoteMeta.fromJson(json);
    final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
    final local = rows.isEmpty ? null : rows.first;
    final tombstone = meta.deletedAt != null;

    // A live row belongs under live parents. Under a parent deleted here it
    // goes with that parent (a person's delete wins); a parent this device
    // lacks may still be on its way, which only the caller can find out.
    if (!tombstone) {
      switch (await _parentsOf(txn, json)) {
        case _Parents.live:
          break;
        case _Parents.deleted:
          if (local == null) return const PullApplied(PullOutcome.kept);
          await txn.delete(table, where: 'id = ?', whereArgs: [id]);
          return const PullApplied(PullOutcome.deleted);
        case _Parents.absent:
          return const PullApplied(PullOutcome.orphaned);
      }
    }

    if (local == null) {
      if (tombstone) return const PullApplied(PullOutcome.kept);
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: false);
      return const PullApplied(PullOutcome.inserted);
    }

    final status = local['sync_status'] as String?;
    final localMeta = LocalSyncMeta.fromRow(local);
    final localEditedAt = _editedAtOf(local, localMeta);
    final localTimes = localFieldTimes(local);
    final pending =
        status == SyncStatus.pendingCreate ||
        status == SyncStatus.pendingUpdate;
    // The app's own delete of a dose (dropped from a changed schedule, or
    // deleted with its prescription) loses to a person's change still
    // waiting here, and to the schedule generating the dose again after it.
    // A dose has no children, so bringing it back leaves none behind. It
    // never comes back under a prescription deleted or missing here, nor
    // when the tombstone carries this device's own write (the server
    // deleted what it sent). Every other tombstone wins.
    final ownWrite =
        localMeta.writeId != null && meta.writeId == localMeta.writeId;
    final resurrect =
        tombstone &&
        table == 'dose_logs' &&
        isAutomaticEdit(meta.editedAt) &&
        pending &&
        !ownWrite &&
        (_hasPersonsChange(local, localMeta, localTimes) ||
            _generatedSince(local, meta.deletedAt)) &&
        await _parentsOf(txn, local) == _Parents.live;
    if (tombstone && !resurrect) {
      await txn.delete(table, where: 'id = ?', whereArgs: [id]);
      return const PullApplied(PullOutcome.deleted);
    }

    if (status == SyncStatus.pendingDelete) {
      final guarded = local['delete_guard'] == 'if_pending';
      // Taken or skipped elsewhere: that copy is shown, unless a person
      // here undid it later; the push then sends the undo and the drop.
      if (guarded &&
          json['status'] != 'pending' &&
          !_droppedUndoWins(local, json)) {
        await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
        return const PullApplied(PullOutcome.replaced);
      }
      return const PullApplied(PullOutcome.kept);
    }

    final knownVersion = localMeta.version;
    if (!pending) {
      // A synced row at this version already holds this content.
      if (knownVersion != null && meta.rowVersion <= knownVersion) {
        return const PullApplied(PullOutcome.kept);
      }
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
      return const PullApplied(PullOutcome.replaced);
    }

    final remoteWire = canonicalWire(table, json);
    final localCopy = localWire(table, local);
    if (ownWrite) {
      return _adoptOwnWrite(txn, json, meta, remoteWire, localCopy, localTimes);
    }
    if (knownVersion != null && meta.rowVersion <= knownVersion) {
      return const PullApplied(PullOutcome.kept);
    }

    final merge = mergeRows(
      base: localMeta.base,
      baseTimes: localMeta.baseTimes,
      local: localCopy,
      remote: remoteWire,
      localTimes: localTimes,
      remoteTimes: meta.fieldTimes,
      policy: policy,
    );
    final settled =
        !resurrect &&
        !merge.sendsTimes &&
        sameContent(merge.row, remoteWire, policy);
    await _storeServer(
      txn,
      {...json, ...merge.row, if (resurrect) 'deleted_at': null},
      meta,
      settled ? SyncStatus.synced : SyncStatus.pendingUpdate,
      exists: true,
      base: remoteWire,
      editedAt: settled ? meta.effectiveEditedAt : localEditedAt,
      fieldTimes: settled ? meta.fieldTimes : merge.times,
    );
    return PullApplied(PullOutcome.merged, merge.conflicts);
  }

  /// The server copy carries this device's unconfirmed write: it becomes the
  /// base; the row is in step if nothing changed here since.
  Future<PullApplied> _adoptOwnWrite(
    Transaction txn,
    Map<String, dynamic> json,
    RemoteMeta meta,
    Map<String, Object?> remoteWire,
    Map<String, Object?> localCopy,
    FieldTimes localTimes,
  ) async {
    final id = json['id']! as String;
    if (sameContent(localCopy, remoteWire, policy)) {
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
      return const PullApplied(PullOutcome.replaced);
    }
    await txn.update(
      table,
      {
        ...syncMetaValues(
          version: meta.rowVersion,
          base: remoteWire,
          baseTimes: meta.fieldTimes,
          fieldTimes: timesAgainstBase(
            localWire: localCopy,
            localTimes: localTimes,
            serverWire: remoteWire,
            serverTimes: meta.fieldTimes,
          ),
        ),
        'sync_status': SyncStatus.pendingUpdate,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return const PullApplied(PullOutcome.kept);
  }

  /// Stores the server row [json] as the local row, with [status] and the
  /// bookkeeping of [meta]. [base] defaults to the canonical copy of [json].
  Future<void> _storeServer(
    Transaction txn,
    Map<String, dynamic> json,
    RemoteMeta meta,
    String status, {
    required bool exists,
    Map<String, Object?>? base,
    DateTime? editedAt,
    FieldTimes? fieldTimes,
  }) async {
    final id = json['id']! as String;
    final row = localRowOf(table, json, status);
    if (table == 'medications') {
      // The server's stock, with the changes still waiting here on top.
      row['quantity'] = localStock(
        (json['quantity'] as num?)?.toInt() ?? 0,
        meta.writeId,
        await StockOutboxLocalDatasource.pendingIn(txn, medicationId: id),
      );
    }
    row.addAll(
      syncMetaValues(
        version: meta.rowVersion,
        base: base ?? canonicalWire(table, json),
        baseTimes: meta.fieldTimes,
        editedAt: editedAt ?? meta.effectiveEditedAt,
        fieldTimes: fieldTimes ?? meta.fieldTimes,
      ),
    );
    if (table == 'dose_logs') row['delete_guard'] = null;
    // Update first: an INSERT OR REPLACE would cascade-delete the children.
    final updated = exists
        ? await txn.update(table, row, where: 'id = ?', whereArgs: [id])
        : 0;
    if (updated == 0) {
      await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  // ── Push ───────────────────────────────────────────────────

  /// Pushes the pending local row [row] (`pending_create`, `pending_update`
  /// or `pending_delete`). [userId] fills `user_id` where the table has it.
  /// With [force] every column is sent, whatever the server holds.
  Future<PushResult> pushRow(
    Map<String, Object?> row, {
    required String? userId,
    bool force = false,
  }) async {
    final id = row['id']! as String;
    if (row['sync_status'] == SyncStatus.pendingDelete) {
      await _pushDelete(row, userId: userId);
      return const PushResult(PushOutcome.settled);
    }
    if (force) return _forcePush(row, userId: userId);
    if (await dropUnderDeletedParent(row)) {
      return const PushResult(PushOutcome.settled);
    }
    final conflicts = <MergeConflict>[];
    var local = await _resolveUnknownWrite(row, conflicts);
    for (var attempt = 0; attempt < maxAttempts && local != null; attempt++) {
      final status = local['sync_status'] as String?;
      if (status == SyncStatus.synced) break;
      // Deleted here while this push waited for the server: the delete is
      // what goes out now.
      if (status == SyncStatus.pendingDelete) {
        await _pushDelete(local, userId: userId);
        return PushResult(PushOutcome.settled, conflicts);
      }
      final meta = LocalSyncMeta.fromRow(local);
      if (status == SyncStatus.pendingCreate || meta.version == null) {
        local = await _pushCreate(local, userId: userId, conflicts: conflicts);
        continue;
      }
      final changes = patchColumns(
        policy,
        meta.base,
        localWire(table, local),
        times: localFieldTimes(local),
        baseTimes: meta.baseTimes,
      );
      if (changes.isEmpty) {
        // Edited again since it was read: the next pass sends that edit.
        final marked = await _markSynced(id, local['updated_at']);
        return PushResult(
          marked ? PushOutcome.settled : PushOutcome.pending,
          conflicts,
        );
      }
      final writeId = await _beginWrite(local);
      final times = _sentTimes(local, changes.keys);
      final written = await remote.patch(id, {
        ...changes,
        'write_id': writeId,
        'edited_at': _wireTime(
          writeTime(
                times.values,
                complete: changes.keys
                    .where((c) => !untimedColumns.contains(c))
                    .every(times.containsKey),
              ) ??
              _editedAtOf(local, meta) ??
              now(),
        ),
        'field_edited_at': {
          for (final MapEntry(:key, :value) in times.entries)
            key: value.toJson(),
        },
      }, ifVersion: meta.version);
      if (written != null) {
        return _settle(local, written, conflicts);
      }
      final server = await remote.fetch(id);
      if (server == null) {
        local = await _asCreate(local);
        continue;
      }
      if (RemoteMeta.fromJson(server).writeId == writeId) {
        return _settle(local, server, conflicts);
      }
      local = await _mergeFrom(server, conflicts);
    }
    return PushResult(
      local == null || local['sync_status'] == SyncStatus.synced
          ? PushOutcome.settled
          : PushOutcome.pending,
      conflicts,
    );
  }

  /// "My copy is the truth": every column, whatever version the server
  /// holds, and a row deleted there comes back; a row the server lacks is
  /// inserted.
  Future<PushResult> _forcePush(
    Map<String, Object?> row, {
    required String? userId,
  }) async {
    final id = row['id']! as String;
    final wire = localWire(table, row, userId: userId);
    final writeId = await _beginWrite(row);
    final at = now();
    final columns = writableColumns(policy, wire);
    // Every column it writes is a change made now.
    final times = FieldTimes({
      for (final column in columns.keys)
        if (!untimedColumns.contains(column)) column: FieldTime(at),
    });
    final stamp = {
      'write_id': writeId,
      'edited_at': _wireTime(at),
      'field_edited_at': times.toJson(),
    };
    var server = await remote.patch(id, {
      ...columns,
      // A live row here is live on the server too, whoever deleted it there.
      'deleted_at': null,
      ...stamp,
    });
    if (server == null) {
      await remote.insertIfAbsent([
        {...wire, ...stamp, 'field_edited_at': insertTimes(times)},
      ]);
      server = await remote.fetch(id);
      if (server == null) {
        throw StateError('$table/$id is not on the server after insert');
      }
    }
    if (server['deleted_at'] != null) {
      // Its parent is deleted there (its own force push failed): keep this
      // copy for the next try.
      throw StateError('$table/$id: a parent is deleted on the server');
    }
    return _settle(row, server, const []);
  }

  /// A row whose last write attempt never got an answer: when the server
  /// holds that write, it becomes the base. Returns the row to go on with,
  /// or null when it is gone.
  Future<Map<String, Object?>?> _resolveUnknownWrite(
    Map<String, Object?> row,
    List<MergeConflict> conflicts,
  ) async {
    final id = row['id']! as String;
    final writeId = row['sync_write_id'] as String?;
    if (writeId == null) return row;
    final server = await remote.fetch(id);
    if (server != null && RemoteMeta.fromJson(server).writeId == writeId) {
      final db = await _db;
      final applied = await db.transaction((txn) => _applyPulled(txn, server));
      conflicts.addAll(applied.conflicts);
    } else {
      await _update(id, {'sync_write_id': null});
    }
    return _read(id);
  }

  /// Inserts the row where the server lacks it and reads it back.
  ///
  /// A medication's insert carries its stock, which already holds every
  /// stock change still waiting for it here: those changes leave the
  /// outbox when the insert is prepared, in the same transaction that
  /// stores its write id, so neither a settled insert nor one found again
  /// after a lost answer counts them twice (design section 7.5). A change
  /// made after that waits, and goes out once the insert has settled. When
  /// the server turns out to hold another copy, the insert was ignored:
  /// the changes go back to the outbox, in their place, and apply to that
  /// copy.
  Future<Map<String, Object?>?> _pushCreate(
    Map<String, Object?> local, {
    required String? userId,
    required List<MergeConflict> conflicts,
  }) async {
    final id = local['id']! as String;
    if (LocalSyncMeta.fromRow(local).version == null &&
        local['sync_status'] != SyncStatus.pendingCreate) {
      // An update with no known server copy: read it first.
      final server = await remote.fetch(id);
      if (server != null) return _mergeFrom(server, conflicts);
    }
    final (:row, :writeId, :carried) = await _beginCreate(id);
    if (row == null) return null;
    final meta = LocalSyncMeta.fromRow(row);
    await remote.insertIfAbsent([
      {
        ...localWire(table, row, userId: userId),
        'write_id': writeId,
        'edited_at': _wireTime(_editedAtOf(row, meta) ?? now()),
        // Empty when no column changed since the row was made here: the
        // server then reads edited_at for every column, as this device does.
        'field_edited_at': insertTimes(
          FieldTimes.decode(row['field_edited_at']),
        ),
      },
    ]);
    final server = await remote.fetch(id);
    if (server == null) {
      throw StateError('$table/$id is not on the server after insert');
    }
    if (RemoteMeta.fromJson(server).writeId == writeId) {
      await settlePushedRow(await _db, table, pushed: row, server: server);
      return _read(id);
    }
    await _putBackStock(id, carried);
    return _mergeFrom(server, conflicts);
  }

  /// Stores a fresh write id on the row [id] and reads the row back, in one
  /// transaction; for a medication, the stock changes waiting for it leave
  /// the outbox there too ([carried], as outbox rows). [row] is null when
  /// the row is gone.
  Future<
    ({
      Map<String, Object?>? row,
      String writeId,
      List<Map<String, Object?>> carried,
    })
  >
  _beginCreate(String id) async {
    final writeId = newWriteId();
    final db = await _db;
    return db.transaction((txn) async {
      await txn.update(
        table,
        {'sync_write_id': writeId},
        where: 'id = ?',
        whereArgs: [id],
      );
      final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) {
        return (
          row: null,
          writeId: writeId,
          carried: const <Map<String, Object?>>[],
        );
      }
      var carried = const <Map<String, Object?>>[];
      if (table == 'medications') {
        carried = await txn.query(
          StockOutboxLocalDatasource.table,
          where: 'medication_id = ?',
          whereArgs: [id],
          orderBy: 'seq',
        );
        await txn.delete(
          StockOutboxLocalDatasource.table,
          where: 'medication_id = ?',
          whereArgs: [id],
        );
      }
      return (row: rows.first, writeId: writeId, carried: carried);
    });
  }

  /// Puts the stock changes [carried] for medication [id] back into the
  /// outbox, each in its old place (its `seq`), unless the medication is
  /// gone here.
  Future<void> _putBackStock(
    String id,
    List<Map<String, Object?>> carried,
  ) async {
    if (carried.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        table,
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return;
      for (final op in carried) {
        await txn.insert(StockOutboxLocalDatasource.table, op);
      }
    });
  }

  /// Sends a person's delete, or, for a dose the app dropped from a changed
  /// schedule, a delete that applies only while the dose is still pending.
  Future<void> _pushDelete(
    Map<String, Object?> row, {
    required String? userId,
  }) async {
    final id = row['id']! as String;
    final guarded = table == 'dose_logs' && row['delete_guard'] == 'if_pending';
    final createMayLand = row['sync_write_id'] != null;
    final writeId = await _beginWrite(row);
    final deletedAt = _wireTime(now());
    final editedAt = _wireTime(guarded ? automaticEditedAt : now());
    final written = await remote.patch(
      id,
      {
        'deleted_at': deletedAt,
        'write_id': writeId,
        'edited_at': editedAt,
        // A delete changes no column that has an edit time.
        'field_edited_at': const <String, Object?>{},
      },
      ifStatus: guarded ? 'pending' : null,
      ifLive: guarded,
    );
    if (written == null) {
      final server = await remote.fetch(id);
      if (server == null) {
        if (createMayLand && !guarded) {
          // Its create may still land; a tombstone in its place wins.
          await remote.insertIfAbsent([
            {
              ...localWire(table, row, userId: userId),
              'deleted_at': deletedAt,
              'write_id': writeId,
              'edited_at': editedAt,
              'field_edited_at': insertTimes(
                FieldTimes.decode(row['field_edited_at']),
              ),
            },
          ]);
        }
      } else if (server['deleted_at'] == null) {
        if (!guarded || server['status'] == 'pending') {
          // Still live and still pending: the delete is tried again later.
          throw StateError('$table/$id: the server refused the delete');
        }
        if (!_droppedUndoWins(row, server)) {
          // Taken or skipped elsewhere meanwhile: keep that copy.
          final db = await _db;
          await db.transaction((txn) async {
            await txn.update(
              table,
              {'sync_status': SyncStatus.synced, 'delete_guard': null},
              where: 'id = ?',
              whereArgs: [id],
            );
            await _applyPulled(txn, server);
          });
          return;
        }
        // A person here made the dose pending again after the change that
        // made it taken or skipped there: that undo goes out first, then
        // the drop applies to it.
        await _sendDroppedUndo(row, server);
        final again = await remote.patch(
          id,
          {
            'deleted_at': deletedAt,
            'write_id': await _beginWrite(row),
            'edited_at': editedAt,
            'field_edited_at': const <String, Object?>{},
          },
          ifStatus: 'pending',
          ifLive: true,
        );
        if (again == null) {
          throw StateError('$table/$id changed again; the drop is tried later');
        }
      }
    }
    final db = await _db;
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  /// True when the dose [local], dropped from its schedule here, carries a
  /// change to its status that beats the server copy [server]'s: a
  /// person's undo here, later than the take or skip there (cycle review
  /// I-2). The drop only fills the column times, so the undo's time is
  /// still the row's.
  bool _droppedUndoWins(
    Map<String, Object?> local,
    Map<String, dynamic> server,
  ) {
    if (local['status'] != 'pending') return false;
    final meta = LocalSyncMeta.fromRow(local);
    final merged = mergeRows(
      base: meta.base,
      baseTimes: meta.baseTimes,
      local: localWire(table, local),
      remote: canonicalWire(table, server),
      localTimes: localFieldTimes(local),
      remoteTimes: RemoteMeta.fromJson(server).fieldTimes,
      policy: policy,
    );
    return merged.row['status'] == 'pending';
  }

  /// Sends the undo [local] carries (its status group) to the server copy
  /// [server], at that copy's version, and moves the base to the answer.
  /// Throws when the copy moved meanwhile: the drop is tried later.
  Future<void> _sendDroppedUndo(
    Map<String, Object?> local,
    Map<String, dynamic> server,
  ) async {
    final id = local['id']! as String;
    final wire = localWire(table, local);
    const group = ['status', 'taken_time'];
    final times = _sentTimes(local, group);
    final updatedAt = local['updated_at'];
    final written = await remote.patch(id, {
      for (final column in group) column: wire[column],
      'write_id': await _beginWrite(local),
      // The drop set the row's own time to the automatic one; the undo
      // is a person's change, made when the row was last stamped.
      'edited_at': _wireTime(
        writeTime(times.values, complete: group.every(times.containsKey)) ??
            (updatedAt is String ? DateTime.tryParse(updatedAt) : null) ??
            now(),
      ),
      'field_edited_at': {
        for (final MapEntry(:key, :value) in times.entries) key: value.toJson(),
      },
    }, ifVersion: RemoteMeta.fromJson(server).rowVersion);
    if (written == null) {
      throw StateError('$table/$id changed again; the drop is tried later');
    }
    final meta = RemoteMeta.fromJson(written);
    await _update(
      id,
      syncMetaValues(
        version: meta.rowVersion,
        base: canonicalWire(table, written),
        baseTimes: meta.fieldTimes,
      ),
    );
  }

  // ── Many rows at once ──────────────────────────────────────

  /// How many rows one bulk request names. Their ids travel in the URL,
  /// which keeps it well under common URL limits.
  static const bulkSize = 100;

  /// True when the pending row [row] has to be read from the server before
  /// it can be pushed: its last write's answer never came
  /// (`sync_write_id`), or it is an update with no known server copy (a
  /// sign-in marks every row so, and so does an upgrade).
  static bool needsServerCopy(Map<String, Object?> row) {
    final status = row['sync_status'];
    if (status != SyncStatus.pendingCreate &&
        status != SyncStatus.pendingUpdate) {
      return false;
    }
    return row['sync_write_id'] != null ||
        (status == SyncStatus.pendingUpdate && row['sync_version'] == null);
  }

  /// Reads the server copies of [rows] ([needsServerCopy]) in requests of
  /// [bulkSize] and applies each, as the per-row push would one by one
  /// (cycle review I-4): this device's own write is adopted; a write id the
  /// server copy does not carry is cleared; a copy is merged into a row
  /// with no base; an update the server lacks becomes a create, so a dose
  /// joins the batch of new doses. Returns the rows it could not read (the
  /// request failed), with the error, and the groups the merges decided.
  Future<BulkPushResult> prefetch(List<Map<String, Object?>> rows) async {
    final result = BulkPushResult();
    final failed = result.failed;
    final ids = [for (final r in rows) r['id']! as String];
    for (var start = 0; start < ids.length; start += bulkSize) {
      final chunk = ids.sublist(start, (start + bulkSize).clamp(0, ids.length));
      final List<Map<String, dynamic>> server;
      try {
        server = await remote.fetchMany(chunk);
      } catch (e) {
        failed.add((chunk, e));
        continue;
      }
      final byId = {for (final r in server) r['id']! as String: r};
      final db = await _db;
      await db.transaction((txn) async {
        for (final id in chunk) {
          final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
          if (rows.isEmpty || !needsServerCopy(rows.first)) continue;
          final local = rows.first;
          final copy = byId[id];
          final writeId = local['sync_write_id'];
          if (writeId != null && copy?['write_id'] != writeId) {
            await txn.update(
              table,
              {'sync_write_id': null},
              where: 'id = ?',
              whereArgs: [id],
            );
          }
          if (copy != null) {
            final applied = await _applyPulled(txn, copy);
            if (applied.conflicts.isNotEmpty) {
              result.conflicts[id] = applied.conflicts;
            }
          } else if (local['sync_status'] == SyncStatus.pendingUpdate &&
              local['sync_version'] == null) {
            await txn.update(
              table,
              {...clearedSyncMeta, 'sync_status': SyncStatus.pendingCreate},
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }
      });
    }
    return result;
  }

  /// True when the dose [row] can go out in a bulk write of the app's own
  /// "missed" ([pushAutomaticMissed]): a `pending_update` at a known
  /// version, with no unanswered write, whose only change since its base
  /// is its status, from pending to missed, made by the app.
  bool isAutomaticMissed(Map<String, Object?> row) {
    if (table != 'dose_logs' ||
        row['sync_status'] != SyncStatus.pendingUpdate ||
        row['sync_version'] == null ||
        row['sync_write_id'] != null ||
        row['status'] != 'missed') {
      return false;
    }
    final meta = LocalSyncMeta.fromRow(row);
    final base = meta.base;
    if (base == null || base['status'] != 'pending') return false;
    final times = localFieldTimes(row);
    final changes = patchColumns(
      policy,
      base,
      localWire(table, row),
      times: times,
      baseTimes: meta.baseTimes,
    );
    return changes.length == 1 &&
        changes.containsKey('status') &&
        (times.of('status')?.automatic ?? false);
  }

  /// Sends the app's own "missed" of the doses [rows] ([isAutomaticMissed])
  /// in bulk (cycle review I-5): one conditional update per version and
  /// [bulkSize] rows, which writes only rows still at that version and
  /// still pending there, so a change made elsewhere is never overwritten
  /// and a dose the server already holds as missed is not written again.
  /// The rows it wrote settle; the others are read in one request each and
  /// merged (a take elsewhere wins). A row that stays pending goes out one
  /// by one afterwards. Returns what happened to each row.
  Future<BulkPushResult> pushAutomaticMissed(List<Map<String, Object?>> rows) {
    final byVersion = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      byVersion.putIfAbsent(row['sync_version']! as int, () => []).add(row);
    }
    final missed = FieldTime.automaticChange;
    return _bulk(
      [
        for (final MapEntry(key: version, value: group) in byVersion.entries)
          (group, version),
      ],
      changes: (writeId) => {
        'status': 'missed',
        'write_id': writeId,
        'edited_at': _wireTime(automaticEditedAt),
        'field_edited_at': {'status': missed.toJson()},
      },
      ifStatus: 'pending',
      onWritten: (row, server) async =>
          settlePushedRow(await _db, table, pushed: row, server: server),
      onUnwritten: (txn, row, server) async => server == null
          ? const <MergeConflict>[]
          : (await _applyPulled(txn, server)).conflicts,
    );
  }

  /// Sends the guarded deletes of the doses [rows] (dropped from their
  /// schedule, `pending_delete` with `delete_guard = if_pending`) in bulk:
  /// one update per [bulkSize] rows, applied only where the dose is still
  /// live and pending. A dose the server no longer has, or holds deleted,
  /// goes here too; one taken or skipped there is stored as that copy. A
  /// dose that is still live and pending there, or that carries an undo
  /// made here ([_droppedUndoWins]), is left for the one-by-one push.
  Future<BulkPushResult> pushGuardedDeletes(List<Map<String, Object?>> rows) {
    final deletedAt = _wireTime(now());
    return _bulk(
      [(rows, null)],
      changes: (writeId) => {
        'deleted_at': deletedAt,
        'write_id': writeId,
        'edited_at': _wireTime(automaticEditedAt),
        'field_edited_at': const <String, Object?>{},
      },
      ifStatus: 'pending',
      ifLive: true,
      onWritten: (row, server) async {
        final db = await _db;
        await db.delete(table, where: 'id = ?', whereArgs: [row['id']]);
        return false;
      },
      onUnwritten: (txn, row, server) async {
        final id = row['id']! as String;
        if (server == null || server['deleted_at'] != null) {
          await txn.delete(table, where: 'id = ?', whereArgs: [id]);
        } else if (server['status'] != 'pending' &&
            !_droppedUndoWins(row, server)) {
          await txn.update(
            table,
            {'sync_status': SyncStatus.synced, 'delete_guard': null},
            where: 'id = ?',
            whereArgs: [id],
          );
          return (await _applyPulled(txn, server)).conflicts;
        }
        return const <MergeConflict>[];
      },
    );
  }

  /// One bulk write per `(rows, version)` group, [bulkSize] rows at a
  /// time: a write id stored on every row first, then [changes] sent with
  /// the conditions. [onWritten] settles a row the server wrote (true: it
  /// still has changes to push). A row it did not write gets its write id
  /// cleared and, unless it changed here since it was read (then the
  /// one-by-one push takes it), [onUnwritten] applies the server copy
  /// (null: none) in the same transaction.
  Future<BulkPushResult> _bulk(
    List<(List<Map<String, Object?>>, int?)> groups, {
    required Map<String, Object?> Function(String writeId) changes,
    required Future<bool> Function(
      Map<String, Object?> row,
      Map<String, dynamic> server,
    )
    onWritten,
    required Future<List<MergeConflict>> Function(
      Transaction txn,
      Map<String, Object?> row,
      Map<String, dynamic>? server,
    )
    onUnwritten,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    final result = BulkPushResult();
    final db = await _db;
    for (final (rows, version) in groups) {
      for (var start = 0; start < rows.length; start += bulkSize) {
        final chunk = rows.sublist(
          start,
          (start + bulkSize).clamp(0, rows.length),
        );
        final ids = [for (final r in chunk) r['id']! as String];
        final writeId = newWriteId();
        final List<Map<String, dynamic>> written;
        try {
          await db.transaction((txn) async {
            for (final id in ids) {
              await txn.update(
                table,
                {'sync_write_id': writeId},
                where: 'id = ?',
                whereArgs: [id],
              );
            }
          });
          written = await remote.patchMany(
            ids,
            changes(writeId),
            ifVersion: version,
            ifStatus: ifStatus,
            ifLive: ifLive,
          );
        } catch (e) {
          // The write may have landed: the write ids stay, and the next
          // cycle reads these rows first.
          result.failed.add((ids, e));
          continue;
        }
        final byId = {for (final r in written) r['id']! as String: r};
        final rest = <Map<String, Object?>>[];
        for (final row in chunk) {
          final id = row['id']! as String;
          final server = byId[id];
          if (server == null) {
            rest.add(row);
            continue;
          }
          (await onWritten(row, server) ? result.pending : result.settled).add(
            id,
          );
        }
        if (rest.isEmpty) continue;
        final restIds = [for (final r in rest) r['id']! as String];
        final Map<String, Map<String, dynamic>> copies;
        try {
          copies = {
            for (final r in await remote.fetchMany(restIds))
              r['id']! as String: r,
          };
        } catch (e) {
          result.failed.add((restIds, e));
          continue;
        }
        for (final row in rest) {
          final id = row['id']! as String;
          await db.transaction((txn) async {
            // Nothing was written with it.
            await txn.update(
              table,
              {'sync_write_id': null},
              where: 'id = ? AND sync_write_id = ?',
              whereArgs: [id, writeId],
            );
            final current = await txn.query(
              table,
              where: 'id = ? AND sync_status = ? AND updated_at IS ?',
              whereArgs: [id, row['sync_status'], row['updated_at']],
            );
            if (current.isEmpty) return;
            final conflicts = await onUnwritten(txn, current.first, copies[id]);
            if (conflicts.isNotEmpty) result.conflicts[id] = conflicts;
          });
          final after = await _read(id);
          (after == null || after['sync_status'] == SyncStatus.synced
                  ? result.settled
                  : result.pending)
              .add(id);
        }
      }
    }
    return result;
  }

  // ── Helpers ────────────────────────────────────────────────

  /// The `field_edited_at` an insert sends: [times], and under `@wipe` the
  /// "delete all data" generation this device has applied, which the
  /// server compares with the account's last wipe (a key no column has, so
  /// the server keeps no entry for it).
  Map<String, Object?> insertTimes(FieldTimes times) => {
    ...times.toJson(),
    wipeSeenKey: ?wipeSeen?.call(),
  };

  /// Deletes the pending row [row] here, unsent, when a parent it names is
  /// deleted here or missing: that delete wins, and the server deletes the
  /// row with its parent. Returns whether it did.
  Future<bool> dropUnderDeletedParent(Map<String, Object?> row) async {
    final db = await _db;
    return db.transaction((txn) async {
      if (await _parentsOf(txn, row) == _Parents.live) return false;
      await txn.delete(table, where: 'id = ?', whereArgs: [row['id']]);
      return true;
    });
  }

  /// How the parents [row] names stand here.
  Future<_Parents> _parentsOf(
    DatabaseExecutor db,
    Map<String, Object?> row,
  ) async {
    var state = _Parents.live;
    for (final (parent, id) in parentsOf(table, row)) {
      final rows = await db.query(
        parent,
        columns: ['sync_status'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) {
        state = _Parents.absent;
      } else if (rows.first['sync_status'] == SyncStatus.pendingDelete) {
        return _Parents.deleted;
      }
    }
    return state;
  }

  /// True when [local] is a dose the schedule generated here, not sent yet,
  /// after the app's own delete at [deletedAt]: the newer of two changes
  /// the app made. A row without a creation time counts as newer.
  static bool _generatedSince(Map<String, Object?> local, DateTime? deletedAt) {
    if (local['sync_status'] != SyncStatus.pendingCreate) return false;
    final raw = local['created_at'];
    final created = raw is String ? DateTime.tryParse(raw) : null;
    return created == null || deletedAt == null || created.isAfter(deletedAt);
  }

  /// Stores a fresh write id on the row before it is sent, so an answer
  /// that never arrives can be recognised later.
  Future<String> _beginWrite(Map<String, Object?> local) async {
    final writeId = newWriteId();
    await _update(local['id']! as String, {'sync_write_id': writeId});
    return writeId;
  }

  Future<PushResult> _settle(
    Map<String, Object?> local,
    Map<String, dynamic> server,
    List<MergeConflict> conflicts,
  ) async {
    final pending = await settlePushedRow(
      await _db,
      table,
      pushed: local,
      server: server,
    );
    return PushResult(
      pending ? PushOutcome.pending : PushOutcome.settled,
      conflicts,
    );
  }

  /// Merges the server copy [server] into the local row and returns the
  /// row as stored.
  Future<Map<String, Object?>?> _mergeFrom(
    Map<String, dynamic> server,
    List<MergeConflict> conflicts,
  ) async {
    final db = await _db;
    final applied = await db.transaction((txn) => _applyPulled(txn, server));
    conflicts.addAll(applied.conflicts);
    return _read(server['id']! as String);
  }

  /// The server no longer has the row (a purge): send it as new, unless it
  /// was deleted here meanwhile.
  Future<Map<String, Object?>?> _asCreate(Map<String, Object?> local) async {
    final id = local['id']! as String;
    final db = await _db;
    await db.update(
      table,
      {...clearedSyncMeta, 'sync_status': SyncStatus.pendingCreate},
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.pendingDelete],
    );
    return _read(id);
  }

  /// Marks the row synced if it is still the update this push read (same
  /// `updated_at`, and not deleted since); false when it is not.
  Future<bool> _markSynced(String id, Object? pushedUpdatedAt) async {
    final db = await _db;
    final marked = await db.update(
      table,
      {'sync_status': SyncStatus.synced, 'sync_write_id': null},
      where: 'id = ? AND updated_at IS ? AND sync_status = ?',
      whereArgs: [id, pushedUpdatedAt, SyncStatus.pendingUpdate],
    );
    return marked > 0;
  }

  Future<void> _update(String id, Map<String, Object?> values) async {
    final db = await _db;
    await db.update(table, values, where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, Object?>?> _read(String id) async {
    final db = await _db;
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The known edit times of [columns] of the local row [local].
  static Map<String, FieldTime> _sentTimes(
    Map<String, Object?> local,
    Iterable<String> columns,
  ) => localFieldTimes(local).resolved(columns);

  /// True when a column the local row changed since its base carries a
  /// person's change (or one of unknown time), not only the app's own.
  bool _hasPersonsChange(
    Map<String, Object?> local,
    LocalSyncMeta meta,
    FieldTimes times,
  ) {
    final changed = changedColumns(meta.base, localWire(table, local), policy);
    return changed.isNotEmpty &&
        beats(times.strongestOf(changed), FieldTime.automaticChange);
  }

  static DateTime? _editedAtOf(Map<String, Object?> row, LocalSyncMeta meta) =>
      meta.editedAt ??
      (row['updated_at'] is String
          ? DateTime.tryParse(row['updated_at']! as String)
          : null);

  static String _wireTime(DateTime time) => time.toUtc().toIso8601String();
}

/// The key under which an insert's `field_edited_at` carries the wipe
/// generation its device has applied.
const wipeSeenKey = '@wipe';

/// What a bulk push did, by row id.
class BulkPushResult {
  /// In step with the server now, or gone.
  final List<String> settled = [];

  /// Still to be pushed one by one.
  final List<String> pending = [];

  /// The requests that failed: the rows they named, and the error.
  final List<(List<String>, Object)> failed = [];

  /// The groups a merge with the server copy decided, by row id.
  final Map<String, List<MergeConflict>> conflicts = {};
}

/// The edit time a write that carries the column times [times] sends as
/// its row's `edited_at`: the latest person's change; the automatic mark
/// (1970) when every change is the app's own, so the server keeps
/// `updated_at`; null when there is none. [complete] is false when a sent
/// column has no known time: the write is then never sent as automatic
/// (the server would stamp that column as the app's own change, and an
/// unknown time beats those), and null lets the caller use the row time.
DateTime? writeTime(Iterable<FieldTime> times, {bool complete = true}) {
  DateTime? latest;
  var any = false;
  for (final time in times) {
    any = true;
    if (time.automatic) continue;
    if (latest == null || time.at.isAfter(latest)) latest = time.at;
  }
  return latest ?? (any && complete ? automaticEditedAt : null);
}

/// The columns of [local] a push sends: those changed since [base] (see
/// [changedColumns]; [times] and [baseTimes] are the local and the base's
/// column times), plus `deleted_at: null` when the base is a tombstone this
/// row brings back.
Map<String, Object?> patchColumns(
  MergePolicy policy,
  Map<String, Object?>? base,
  Map<String, Object?> local, {
  FieldTimes? times,
  FieldTimes? baseTimes,
}) => {
  for (final column in changedColumns(
    base,
    local,
    policy,
    times: times,
    baseTimes: baseTimes,
  ))
    column: local[column],
  if (base?['deleted_at'] != null && local['deleted_at'] == null)
    'deleted_at': null,
};

/// Every column of [local] a client writes: bookkeeping and server-owned
/// columns left out.
Map<String, Object?> writableColumns(
  MergePolicy policy,
  Map<String, Object?> local,
) => {
  for (final entry in local.entries)
    if (!MergePolicy.bookkeeping.contains(entry.key) &&
        !policy.serverOwned.contains(entry.key))
      entry.key: entry.value,
};
