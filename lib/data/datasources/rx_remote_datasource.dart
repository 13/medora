/// Medora - The server tables of prescriptions (sync v2).
library;

import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that creates `persons`, `rx` and `rx_dispensings`.
const rxMigration = 'supabase/migrations/20260923000000_rx.sql';

class RxRemoteDatasource {
  RxRemoteDatasource(SupabaseClient client)
    : persons = PostgrestSyncTable(
        client,
        'persons',
        migration: rxMigration,
        tableMigration: rxMigration,
      ),
      rx = PostgrestSyncTable(
        client,
        'rx',
        migration: rxMigration,
        tableMigration: rxMigration,
      ),
      dispensings = PostgrestSyncTable(
        client,
        'rx_dispensings',
        migration: rxMigration,
        tableMigration: rxMigration,
      );

  final SyncTable persons;
  final SyncTable rx;
  final SyncTable dispensings;
}
