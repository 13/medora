/// Medora - Medication Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the `ean` column this datasource sends.
const medicationEanMigration =
    'supabase/migrations/20260916000000_medication_ean.sql';

/// [error] read as a missing `medications` column (see [missingColumn]),
/// else null.
MissingColumnException? missingMedicationColumn(Object error) => missingColumn(
  error,
  table: AppConstants.medicationsTable,
  migration: medicationEanMigration,
  fallbackColumn: 'ean',
);

class MedicationRemoteDatasource {
  MedicationRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.medicationsTable,
        migration: medicationEanMigration,
        fallbackColumn: 'ean',
      ),
      stock = PostgrestStockRemote(client);

  /// The `medications` rows.
  final SyncTable rows;

  /// `apply_stock_change`.
  final StockRemote stock;
}
