/// Medora - Medication Remote Datasource
///
/// Handles all Supabase interactions for medications.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/pull_page.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/sync/push_settle.dart';
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

/// Runs [send], turning a missing-column rejection into a
/// [MissingColumnException] that names [medicationEanMigration] (review I2).
/// Every other error passes through untouched.
Future<T> mapMedicationSchemaErrors<T>(Future<T> Function() send) =>
    mapMissingColumn(
      send,
      table: AppConstants.medicationsTable,
      migration: medicationEanMigration,
      fallbackColumn: 'ean',
    );

class MedicationRemoteDatasource {
  MedicationRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// One page of the rows changed after [since] (UTC; all rows when null),
  /// tombstones included: the rows after [after] in the pull order, at most
  /// [pullPageSize] of them. See `pullPage`.
  Future<List<MedicationModel>> getMedicationsSince(
    DateTime? since, {
    PullKey? after,
  }) async {
    final response = await pullPage(
      _client.from(AppConstants.medicationsTable).select(),
      since: since,
      after: after,
    );
    return response.map(MedicationModel.fromJson).toList();
  }

  /// The remote row's `updated_at`, or null when the row is not there.
  ///
  /// The push phase uses it to leave a remote row alone when it is newer than
  /// the local pending edit (true last-write-wins).
  Future<DateTime?> getUpdatedAt(String id) async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select('updated_at')
        .eq('id', id)
        .maybeSingle();
    final raw = response?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// Get a single medication by ID.
  /// The single row with [id], or null when the server does not have it.
  Future<MedicationModel?> getMedicationById(String id) async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select()
        .eq('id', id)
        .maybeSingle();

    return response == null ? null : MedicationModel.fromJson(response);
  }

  /// Upsert a medication (insert or update). Returns the `updated_at` the
  /// server gave this write (see `settlePushedRow`). An answer without
  /// the written row is an error, so the row stays pending.
  Future<DateTime?> upsertMedication(MedicationModel model) =>
      mapMedicationSchemaErrors(() async {
        final response = await _client
            .from(AppConstants.medicationsTable)
            .upsert(model.toJson())
            .select('updated_at')
            .single();
        return serverStampOf(response);
      });

  /// Delete a medication.
  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deleteMedication(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.medicationsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }
}
