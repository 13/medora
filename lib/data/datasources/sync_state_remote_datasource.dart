/// Medora - What the server says about sync itself (sync v2).
library;

import 'package:medora/data/datasources/schema_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration this build needs (see `docs/architecture.md`, Sync).
const syncV2Migration = 'supabase/migrations/20260918000000_sync_v2.sql';

/// The sync schema this build speaks.
const requiredSyncSchema = 2;

/// One answer of `medora_sync_state()`.
class SyncServerState {
  const SyncServerState({
    required this.schema,
    required this.horizon,
    this.wipeGeneration = 0,
    this.wipedAt,
  });

  final int schema;

  /// Every transaction below this id has finished (see `pullPage`).
  final int horizon;

  /// How many times the signed-in user used "delete all data"
  /// (`medora_delete_all_data`); 0 when never.
  final int wipeGeneration;

  /// When the last of those ran (server time); null when never.
  final DateTime? wipedAt;
}

class SyncStateRemoteDatasource {
  SyncStateRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// The server's sync state. Throws [MissingMigrationException] when the
  /// project lacks [syncV2Migration]; any other error passes through.
  Future<SyncServerState> read() async {
    final Object? raw;
    try {
      raw = await _client.rpc<dynamic>('medora_sync_state');
    } on PostgrestException catch (e) {
      if (isMissingFunction(e)) {
        throw MissingMigrationException(migration: syncV2Migration, cause: e);
      }
      rethrow;
    }
    return parseSyncState(raw);
  }
}

/// PostgREST `PGRST202` (not in the schema cache) or Postgres `42883`
/// (undefined function).
bool isMissingFunction(PostgrestException e) =>
    e.code == 'PGRST202' || e.code == '42883';

/// [raw] read as a sync state; a missing or older schema is a
/// [MissingMigrationException].
SyncServerState parseSyncState(Object? raw) {
  if (raw is! Map) {
    throw const MissingMigrationException(migration: syncV2Migration);
  }
  final schema = (raw['schema'] as num?)?.toInt() ?? 0;
  final horizon = (raw['horizon'] as num?)?.toInt();
  if (schema < requiredSyncSchema || horizon == null) {
    throw MissingMigrationException(migration: syncV2Migration, cause: raw);
  }
  final wipe = raw['wipe'];
  final wipedAt = wipe is Map && wipe['wiped_at'] is String
      ? DateTime.tryParse(wipe['wiped_at'] as String)?.toUtc()
      : null;
  final generation = wipe is Map
      ? (wipe['generation'] as num?)?.toInt() ?? 0
      : 0;
  return SyncServerState(
    schema: schema,
    horizon: horizon,
    // A generation without a time cannot be applied; it reads as none.
    wipeGeneration: wipedAt == null ? 0 : generation,
    wipedAt: wipedAt,
  );
}
