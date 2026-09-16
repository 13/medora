/// Medora - Prescription Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/sync/push_settle.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrescriptionRemoteDatasource {
  PrescriptionRemoteDatasource(this._client);

  final SupabaseClient _client;

  Future<List<PrescriptionModel>> getPrescriptions() async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .isFilter('deleted_at', null)
        .order('start_time');

    return (response as List)
        .map((json) => PrescriptionModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Rows changed after [since] (UTC); all rows when null. Includes tombstones.
  Future<List<PrescriptionModel>> getPrescriptionsSince(DateTime? since) async {
    final base = _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)');
    final filtered = since == null
        ? base
        : base.gt('updated_at', since.toUtc().toIso8601String());
    final response = await filtered.order('updated_at');
    return (response as List)
        .map((json) => PrescriptionModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// The remote row's `updated_at`, or null when the row is not there.
  ///
  /// The push phase uses it to leave a remote row alone when it is newer than
  /// the local pending edit (true last-write-wins).
  Future<DateTime?> getUpdatedAt(String id) async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('updated_at')
        .eq('id', id)
        .maybeSingle();
    final raw = response?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(
    String treatmentId,
  ) async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('treatment_id', treatmentId)
        .isFilter('deleted_at', null)
        .order('start_time');

    return (response as List)
        .map((json) => PrescriptionModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<PrescriptionModel>> getActivePrescriptions() async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('is_active', true)
        .isFilter('deleted_at', null)
        .order('start_time');

    return (response as List)
        .map((json) => PrescriptionModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// The single row with [id], or null when the server does not have it.
  Future<PrescriptionModel?> getPrescriptionById(String id) async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('id', id)
        .maybeSingle();

    return response == null ? null : PrescriptionModel.fromJson(response);
  }

  /// Upsert a prescription (insert or update). Returns the `updated_at` the
  /// server gave this write (see `settlePushedRow`). An answer without
  /// the written row is an error, so the row stays pending.
  Future<DateTime?> upsertPrescription(PrescriptionModel model) async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .upsert(model.toJson())
        .select('updated_at')
        .single();
    return serverStampOf(response);
  }

  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deletePrescription(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.prescriptionsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }
}
