/// Medora - Treatment Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/pull_page.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/sync/push_settle.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the sick-leave columns this datasource sends.
const treatmentSickLeaveMigration =
    'supabase/migrations/20260917000000_treatment_sick_leave.sql';

class TreatmentRemoteDatasource {
  TreatmentRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// One page of the rows changed after [since] (UTC; all rows when null),
  /// tombstones included: the rows after [after] in the pull order, at most
  /// [pullPageSize] of them. See `pullPage`.
  Future<List<TreatmentModel>> getTreatmentsSince(
    DateTime? since, {
    PullKey? after,
  }) async {
    final response = await pullPage(
      _client.from(AppConstants.treatmentsTable).select(),
      since: since,
      after: after,
    );
    return response.map(TreatmentModel.fromJson).toList();
  }

  /// The remote row's `updated_at`, or null when the row is not there.
  ///
  /// The push phase uses it to leave a remote row alone when it is newer than
  /// the local pending edit (true last-write-wins).
  Future<DateTime?> getUpdatedAt(String id) async {
    final response = await _client
        .from(AppConstants.treatmentsTable)
        .select('updated_at')
        .eq('id', id)
        .maybeSingle();
    final raw = response?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// The single row with [id], or null when the server does not have it.
  Future<TreatmentModel?> getTreatmentById(String id) async {
    final response = await _client
        .from(AppConstants.treatmentsTable)
        .select()
        .eq('id', id)
        .maybeSingle();

    return response == null ? null : TreatmentModel.fromJson(response);
  }

  /// Upsert a treatment (insert or update). Returns the `updated_at` the
  /// server gave this write (see `settlePushedRow`). An answer without
  /// the written row is an error, so the row stays pending.
  ///
  /// `toJson` always sends the sick-leave keys, so a project without
  /// [treatmentSickLeaveMigration] rejects every push; that rejection is a
  /// [MissingColumnException] naming the file (review I-2).
  Future<DateTime?> upsertTreatment(TreatmentModel model) => mapMissingColumn(
    () async {
      final response = await _client
          .from(AppConstants.treatmentsTable)
          .upsert(model.toJson())
          .select('updated_at')
          .single();
      return serverStampOf(response);
    },
    table: AppConstants.treatmentsTable,
    migration: treatmentSickLeaveMigration,
    fallbackColumn: 'sick_leave_from',
  );

  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deleteTreatment(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.treatmentsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }
}
