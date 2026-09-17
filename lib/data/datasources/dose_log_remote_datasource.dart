/// Medora - Dose Log Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DoseLogRemoteDatasource {
  DoseLogRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.doseLogsTable,
        select: '*, prescriptions(id, medications(name))',
      );

  /// The `dose_logs` rows. New doses go out with
  /// [SyncTable.insertIfAbsent] in batches (see `SyncService`).
  final SyncTable rows;
}
