/// Medora - Moves attachment bytes between this device and the private
/// storage bucket.
///
/// The rows sync like every other table; this is the bytes. One pass
/// removes the objects of deleted attachments, uploads the files of new
/// ones and records their paths (which the next sync pushes), then sweeps
/// local files no row points at any more. Downloads happen on demand, when
/// an attachment is opened.
///
/// Logs name attachment ids and counts only: never file names, paths or
/// user ids.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/repositories/attachment_repository.dart';
import 'package:medora/services/rerun_guard.dart';
import 'package:path/path.dart' as p;

/// What one [AttachmentTransfer.run] did.
@immutable
class TransferReport {
  const TransferReport({
    this.uploaded = 0,
    this.removed = 0,
    this.swept = 0,
    this.failed = 0,
  });

  static const none = TransferReport();

  final int uploaded;
  final int removed;
  final int swept;
  final int failed;

  bool get isEmpty =>
      uploaded == 0 && removed == 0 && swept == 0 && failed == 0;

  TransferReport operator +(TransferReport o) => TransferReport(
    uploaded: uploaded + o.uploaded,
    removed: removed + o.removed,
    swept: swept + o.swept,
    failed: failed + o.failed,
  );

  @override
  String toString() =>
      'uploaded $uploaded, removed $removed, swept $swept, failed $failed';
}

class AttachmentTransfer {
  AttachmentTransfer({
    required this._local,
    required this._repository,
    required this._files,
    required this._store,
    required this._currentUserId,
    required this._isOnline,
    this._now = systemNow,
  });

  final AttachmentLocalDatasource _local;
  final AttachmentRepository _repository;
  final AttachmentFiles _files;
  final AttachmentStore? _store;
  final String? Function() _currentUserId;
  final bool Function() _isOnline;
  final Now _now;

  final _guard = RerunGuard();

  /// Downloads in flight by attachment id: a second [open] of the same
  /// attachment waits for the first instead of downloading it again.
  final _opening = <String, Future<File?>>{};

  /// Failed items by key, with when they may be tried again. Kept in
  /// memory only: a restart retries everything at once, which is fine.
  final _backoff = <String, ({int failures, DateTime retryAt})>{};

  /// A local file without a row this recent may belong to an `add` that
  /// has written its file but not its row yet, so the sweep leaves it.
  static const sweepGrace = Duration(minutes: 5);

  /// Paths per storage remove request.
  static const removeBatch = 100;

  static const _backoffSteps = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
    Duration(hours: 2),
  ];

  /// How long to wait after the [failures]th failure in a row.
  static Duration backoffAfter(int failures) =>
      _backoffSteps[math.min(math.max(failures, 1), _backoffSteps.length) - 1];

  /// One pass: removals first, then uploads, then the local sweep. Never
  /// throws; failures back off per item and are retried on a later pass. A
  /// call while a pass is running is folded into one more pass of that run,
  /// and returns [TransferReport.none].
  Future<TransferReport> run() async {
    var report = TransferReport.none;
    await _guard.run(() async {
      report += await _pass();
      return 0;
    });
    return report;
  }

  Future<TransferReport> _pass() async {
    final store = _store;
    final uid = _currentUserId();
    if (store == null || uid == null || !_isOnline()) {
      return TransferReport.none;
    }
    var report = TransferReport.none;
    try {
      report += await _removals(store, uid);
      report += await _uploads(store, uid);
      report += TransferReport(swept: await sweep());
    } catch (e) {
      debugPrint('Attachments: transfer pass failed: ${e.runtimeType}');
      report += const TransferReport(failed: 1);
    }
    if (!report.isEmpty) debugPrint('Attachments: $report');
    return report;
  }

  bool _waiting(String key) {
    final b = _backoff[key];
    return b != null && _now().isBefore(b.retryAt);
  }

  void _failed(String key) {
    final failures = (_backoff[key]?.failures ?? 0) + 1;
    _backoff[key] = (
      failures: failures,
      retryAt: _now().add(backoffAfter(failures)),
    );
  }

  /// Removes the queued objects in [uid]'s folder. Another account's
  /// paths (queued before a sign-out) stay queued: this user cannot remove
  /// them, and completing them would forget them.
  Future<TransferReport> _removals(AttachmentStore store, String uid) async {
    final due = [
      for (final path in await _local.pendingRemovals())
        if (path.startsWith('$uid/') && !_waiting('rm:$path')) path,
    ];
    var removed = 0;
    var failed = 0;
    for (var i = 0; i < due.length; i += removeBatch) {
      final batch = due.sublist(i, math.min(i + removeBatch, due.length));
      try {
        await store.remove(batch);
      } catch (e) {
        debugPrint(
          'Attachments: removing ${batch.length} objects failed: '
          '${e.runtimeType}',
        );
        for (final path in batch) {
          _failed('rm:$path');
        }
        failed += batch.length;
        continue;
      }
      for (final path in batch) {
        await _local.completeRemoval(path);
        _backoff.remove('rm:$path');
        removed++;
      }
    }
    return TransferReport(removed: removed, failed: failed);
  }

  Future<TransferReport> _uploads(AttachmentStore store, String uid) async {
    var uploaded = 0;
    var failed = 0;
    for (final row in await _local.getAwaitingUpload()) {
      final a = row.toDomain();
      if (row.deletedAt != null || _waiting(a.id)) continue;
      // Another account's row, left on this device: not ours to upload.
      if (a.userId != null && a.userId != uid) continue;
      final File file;
      final Uint8List bytes;
      try {
        file = await _files.fileFor(a);
        if (!file.existsSync()) {
          // Its file may still be being written; the next pass looks again.
          debugPrint('Attachments: ${a.id} has no file yet');
          continue;
        }
        bytes = await file.readAsBytes();
      } catch (e) {
        debugPrint('Attachments: reading ${a.id} failed: ${e.runtimeType}');
        _failed(a.id);
        failed++;
        continue;
      }
      final path = '$uid/${a.fileName}';
      try {
        await store.upload(path, bytes, mime: a.mime);
      } catch (e) {
        debugPrint('Attachments: uploading ${a.id} failed: ${e.runtimeType}');
        _failed(a.id);
        failed++;
        continue;
      }
      // Whoever is signed in now, not at the start of the pass: an account
      // change during the upload must not record the old account's path.
      final marked = await _repository.markUploaded(
        a.id,
        path,
        signedInUserId: _currentUserId(),
      );
      marked.when(
        success: (recorded) {
          _backoff.remove(a.id);
          // False: deleted or gone meanwhile; the object is queued for
          // removal.
          if (recorded) uploaded++;
        },
        failure: (message) {
          debugPrint('Attachments: recording the upload of ${a.id} failed');
          _failed(a.id);
          failed++;
        },
      );
    }
    return TransferReport(uploaded: uploaded, failed: failed);
  }

  /// Deletes local files whose attachment has no row at all. A row that
  /// exists, live or a tombstone still waiting to be pushed, keeps its
  /// file; so does a file written within [sweepGrace]. A `.part` file (a
  /// write still running, or one a kill interrupted) never matches a row,
  /// so it goes once it is older than [sweepGrace].
  ///
  /// Needs no store, user or network: it runs on its own after "delete all
  /// data" on another device removed rows here. Returns how many files went.
  Future<int> sweep() async {
    final ids = (await _local.getAllIds()).toSet();
    final cutoff = _now().subtract(sweepGrace);
    var swept = 0;
    for (final name in await _files.listNames()) {
      if (ids.contains(p.basenameWithoutExtension(name))) continue;
      final modified = await _files.modifiedAt(name);
      if (modified == null || modified.isAfter(cutoff)) continue;
      await _files.delete(name);
      swept++;
    }
    return swept;
  }

  /// The file of [a], downloading it when it is not here yet. Null when it
  /// is not uploaded yet, gone from storage, or cannot be fetched now.
  Future<File?> open(Attachment a) => _opening[a.id] ??= _open(a).whenComplete(
    // A block body: returning the removed future would make this wait on
    // itself.
    () {
      _opening.remove(a.id);
    },
  );

  Future<File?> _open(Attachment a) async {
    try {
      final file = await _files.fileFor(a);
      if (file.existsSync()) return file;
      final store = _store;
      final path = a.remotePath;
      if (store == null || path == null || _currentUserId() == null) {
        return null;
      }
      final bytes = await store.download(path);
      if (bytes.length != a.sizeBytes) {
        debugPrint('Attachments: ${a.id} downloaded with the wrong size');
        return null;
      }
      return await _files.write(a.fileName, bytes);
    } on AttachmentNotFound {
      debugPrint('Attachments: ${a.id} is not in storage');
      return null;
    } catch (e) {
      debugPrint('Attachments: opening ${a.id} failed: ${e.runtimeType}');
      return null;
    }
  }
}
