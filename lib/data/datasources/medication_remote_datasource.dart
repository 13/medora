/// Medora - Medication Remote Datasource
///
/// Handles all Supabase interactions for medications.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/models/medication_model.dart';

class MedicationRemoteDatasource {
  MedicationRemoteDatasource();

  /// Get all medications for the current user.
  Future<List<MedicationModel>> getMedications() async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .order('name');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get a single medication by ID.
  Future<MedicationModel> getMedicationById(String id) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .eq('id', id)
        .single();

    return MedicationModel.fromJson(response);
  }

  /// Search medications by name or active ingredient.
  Future<List<MedicationModel>> searchMedications(String query) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .or('name.ilike.%$query%,active_ingredients.ilike.%$query%')
        .order('name');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Add a new medication.
  Future<void> addMedication(MedicationModel model) async {
    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .insert(model.toJson());
  }

  /// Update a medication.
  Future<void> updateMedication(MedicationModel model) async {
    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .update(model.toJson())
        .eq('id', model.id);
  }

  /// Upsert a medication (insert or update).
  Future<void> upsertMedication(MedicationModel model) async {
    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .upsert(model.toJson());
  }

  /// Delete a medication.
  Future<void> deleteMedication(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .delete()
        .eq('id', id);
  }

  /// Update medication quantity by delta.
  Future<void> updateQuantity(String id, int delta) async {
    final current = await getMedicationById(id);
    final newQuantity = (current.quantity + delta).clamp(0, 999999);

    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .update({'quantity': newQuantity})
        .eq('id', id);
  }
}
