/// Medora - Prescription Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/models/prescription_model.dart';

class PrescriptionRemoteDatasource {
  PrescriptionRemoteDatasource();

  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(
    String treatmentId,
  ) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('treatment_id', treatmentId)
        .order('start_time');

    return (response as List)
        .map(
          (json) =>
              PrescriptionModel.fromJson(json as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<PrescriptionModel>> getActivePrescriptions() async {
    final response = await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('is_active', true)
        .order('start_time');

    return (response as List)
        .map(
          (json) =>
              PrescriptionModel.fromJson(json as Map<String, dynamic>),
        )
        .toList();
  }

  Future<PrescriptionModel> getPrescriptionById(String id) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .select('*, medications(name), treatments(name)')
        .eq('id', id)
        .single();

    return PrescriptionModel.fromJson(response);
  }

  Future<PrescriptionModel> addPrescription(PrescriptionModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .insert(model.toJson())
        .select('*, medications(name), treatments(name)')
        .single();

    return PrescriptionModel.fromJson(response);
  }

  Future<PrescriptionModel> updatePrescription(
    PrescriptionModel model,
  ) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .update(model.toJson())
        .eq('id', model.id)
        .select('*, medications(name), treatments(name)')
        .single();

    return PrescriptionModel.fromJson(response);
  }

  Future<void> deletePrescription(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .delete()
        .eq('id', id);
  }

  Future<void> deactivatePrescription(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .update({'is_active': false})
        .eq('id', id);
  }

  Future<void> reactivatePrescription(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.prescriptionsTable)
        .update({'is_active': true})
        .eq('id', id);
  }
}

