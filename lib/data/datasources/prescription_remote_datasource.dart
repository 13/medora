/// Medora - Prescription Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrescriptionRemoteDatasource {
  PrescriptionRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.prescriptionsTable,
        select: '*, medications(name), treatments(name)',
      );

  /// The `prescriptions` rows.
  final SyncTable rows;
}
