/// Medora - "Delete all data" on the server.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/attachment_remote_datasource.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AccountDataRemoteDatasource {
  AccountDataRemoteDatasource(
    this._client, {
    this._attachments,
    String? Function()? currentUserId,
  }) : _currentUserId = currentUserId ?? (() => _client.auth.currentUser?.id);

  final SupabaseClient _client;

  /// The attachment bytes; null when the project has no attachments.
  final AttachmentStore? _attachments;
  final String? Function() _currentUserId;

  /// Paths per storage remove request.
  static const _removeBatch = 100;

  /// Removes every medication, treatment, prescription and dose of the
  /// signed-in user, and records the wipe for the user's other devices, in
  /// one call (`medora_delete_all_data`, sync v2). Each of those devices
  /// then removes its copies on its next sync (design section 7.9).
  ///
  /// A project without the sync v2 migration has no such function: there
  /// the rows are deleted one table at a time, as before, and other devices
  /// keep their copies (0.4.0 does not sync with such a project anyway).
  ///
  /// Then the attachment files in the user's storage folder go too; the
  /// database cannot delete storage objects itself. A failure there is
  /// thrown (the rows are gone by then, and a retry finishes the job); a
  /// project without the attachments bucket has nothing to remove.
  Future<void> deleteAllData() async {
    await _deleteRows();
    await _deleteAttachmentObjects();
  }

  Future<void> _deleteAttachmentObjects() async {
    final store = _attachments;
    final uid = _currentUserId();
    if (store == null || uid == null) return;
    try {
      final paths = await store.listFolder(uid);
      for (var i = 0; i < paths.length; i += _removeBatch) {
        final end = i + _removeBatch < paths.length
            ? i + _removeBatch
            : paths.length;
        await store.remove(paths.sublist(i, end));
      }
    } on StorageException catch (e) {
      if (!isMissingBucket(e)) rethrow;
    }
  }

  Future<void> _deleteRows() async {
    try {
      await _client.rpc<dynamic>('medora_delete_all_data');
    } on PostgrestException catch (e) {
      if (!isMissingFunction(e)) rethrow;
      // Children first.
      for (final table in const [
        AppConstants.doseLogsTable,
        AppConstants.prescriptionsTable,
        AppConstants.treatmentsTable,
        AppConstants.medicationsTable,
      ]) {
        await _client.from(table).delete().neq('id', '');
      }
    }
  }
}
