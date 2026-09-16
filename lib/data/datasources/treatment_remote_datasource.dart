/// Medora - Treatment Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/pull_page.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/data/sync/push_settle.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TreatmentRemoteDatasource {
  TreatmentRemoteDatasource(this._client);

  final SupabaseClient _client;

  Future<List<TreatmentModel>> getTreatments() async {
    final response = await _client
        .from(AppConstants.treatmentsTable)
        .select()
        .isFilter('deleted_at', null)
        .order('start_date', ascending: false);

    return (response as List)
        .map((json) => TreatmentModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

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

  Future<List<TreatmentModel>> getActiveTreatments() async {
    final response = await _client
        .from(AppConstants.treatmentsTable)
        .select()
        .eq('is_active', true)
        .isFilter('deleted_at', null)
        .order('start_date', ascending: false);

    return (response as List)
        .map((json) => TreatmentModel.fromJson(json as Map<String, dynamic>))
        .toList();
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
  Future<DateTime?> upsertTreatment(TreatmentModel model) async {
    final response = await _client
        .from(AppConstants.treatmentsTable)
        .upsert(model.toJson())
        .select('updated_at')
        .single();
    return serverStampOf(response);
  }

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
