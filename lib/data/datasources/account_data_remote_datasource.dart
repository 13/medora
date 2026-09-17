/// Medora - "Delete all data" on the server.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AccountDataRemoteDatasource {
  AccountDataRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// Removes every medication, treatment, prescription and dose of the
  /// signed-in user, and records the wipe for the user's other devices, in
  /// one call (`medora_delete_all_data`, sync v2). Each of those devices
  /// then removes its copies on its next sync (design section 7.9).
  ///
  /// A project without the sync v2 migration has no such function: there
  /// the rows are deleted one table at a time, as before, and other devices
  /// keep their copies (0.4.0 does not sync with such a project anyway).
  Future<void> deleteAllData() async {
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
