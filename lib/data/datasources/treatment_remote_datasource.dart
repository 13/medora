/// Medora - Treatment Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/treatment_model.dart';
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

  /// Rows changed after [since] (UTC); all rows when null. Includes tombstones.
  Future<List<TreatmentModel>> getTreatmentsSince(DateTime? since) async {
    final base = _client.from(AppConstants.treatmentsTable).select();
    final filtered = since == null
        ? base
        : base.gt('updated_at', since.toUtc().toIso8601String());
    final response = await filtered.order('updated_at');
    return (response as List)
        .map((json) => TreatmentModel.fromJson(json as Map<String, dynamic>))
        .toList();
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

  /// Add a new treatment.
  Future<void> addTreatment(TreatmentModel model) async {
    await _client.from(AppConstants.treatmentsTable).insert(model.toJson());
  }

  /// Update a treatment.
  Future<void> updateTreatment(TreatmentModel model) async {
    await _client
        .from(AppConstants.treatmentsTable)
        .update(model.toJson())
        .eq('id', model.id);
  }

  /// Upsert a treatment (insert or update).
  Future<void> upsertTreatment(TreatmentModel model) async {
    await _client.from(AppConstants.treatmentsTable).upsert(model.toJson());
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
