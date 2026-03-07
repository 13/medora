/// Medora - Treatment Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/models/treatment_model.dart';

class TreatmentRemoteDatasource {
  TreatmentRemoteDatasource();

  Future<List<TreatmentModel>> getTreatments() async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .select()
        .order('start_date', ascending: false);

    return (response as List)
        .map((json) => TreatmentModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<TreatmentModel>> getActiveTreatments() async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .select()
        .eq('is_active', true)
        .order('start_date', ascending: false);

    return (response as List)
        .map((json) => TreatmentModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<TreatmentModel> getTreatmentById(String id) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .select()
        .eq('id', id)
        .single();

    return TreatmentModel.fromJson(response);
  }

  Future<TreatmentModel> addTreatment(TreatmentModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .insert(model.toJson())
        .select()
        .single();

    return TreatmentModel.fromJson(response);
  }

  Future<TreatmentModel> updateTreatment(TreatmentModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .update(model.toJson())
        .eq('id', model.id)
        .select()
        .single();

    return TreatmentModel.fromJson(response);
  }

  Future<void> deleteTreatment(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .delete()
        .eq('id', id);
  }

  Future<TreatmentModel> endTreatment(String id) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.treatmentsTable)
        .update({
          'is_active': false,
          'end_date': DateTime.now().toIso8601String().split('T').first,
        })
        .eq('id', id)
        .select()
        .single();

    return TreatmentModel.fromJson(response);
  }
}

