/// Medora - Prescription Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/prescription_model.dart';
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

  Future<PrescriptionModel> getPrescriptionById(String id) async {
    final response = await _client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('id', id)
        .single();

    return PrescriptionModel.fromJson(response);
  }

  /// Add a new prescription.
  Future<void> addPrescription(PrescriptionModel model) async {
    await _client.from(AppConstants.prescriptionsTable).insert(model.toJson());
  }

  /// Update a prescription.
  Future<void> updatePrescription(PrescriptionModel model) async {
    await _client
        .from(AppConstants.prescriptionsTable)
        .update(model.toJson())
        .eq('id', model.id);
  }

  /// Upsert a prescription (insert or update).
  Future<void> upsertPrescription(PrescriptionModel model) async {
    await _client.from(AppConstants.prescriptionsTable).upsert(model.toJson());
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

  Future<void> deactivatePrescription(String id) async {
    await _client
        .from(AppConstants.prescriptionsTable)
        .update({'is_active': false})
        .eq('id', id);
  }

  Future<void> reactivatePrescription(String id) async {
    await _client
        .from(AppConstants.prescriptionsTable)
        .update({'is_active': true})
        .eq('id', id);
  }
}
