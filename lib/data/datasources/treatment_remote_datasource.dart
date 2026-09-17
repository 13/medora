/// Medora - Treatment Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the sick-leave columns this datasource sends.
const treatmentSickLeaveMigration =
    'supabase/migrations/20260917000000_treatment_sick_leave.sql';

class TreatmentRemoteDatasource {
  TreatmentRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.treatmentsTable,
        migration: treatmentSickLeaveMigration,
        fallbackColumn: 'sick_leave_from',
      );

  /// The `treatments` rows. A write to a project without
  /// [treatmentSickLeaveMigration] fails with a `MissingColumnException`
  /// naming the file.
  final SyncTable rows;
}
