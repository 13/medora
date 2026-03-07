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
        .or('name.ilike.%$query%,active_ingredient.ilike.%$query%')
        .order('name');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get medications expiring within [days].
  Future<List<MedicationModel>> getExpiringSoon({int days = 30}) async {
    final now = DateTime.now();
    final threshold = now.add(Duration(days: days));

    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .gte('expiry_date', now.toIso8601String().split('T').first)
        .lte('expiry_date', threshold.toIso8601String().split('T').first)
        .order('expiry_date');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get medications with low stock.
  Future<List<MedicationModel>> getLowStock() async {
    // Use raw filter: quantity <= minimum_stock_level
    // Supabase doesn't support column-to-column comparison directly,
    // so we fetch all and filter in memory, or use an RPC.
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .order('quantity');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .where((m) => m.quantity <= m.minimumStockLevel)
        .toList();
  }

  /// Get medication by barcode.
  Future<MedicationModel?> getMedicationByBarcode(String barcode) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .select()
        .eq('barcode', barcode)
        .maybeSingle();

    if (response == null) return null;
    return MedicationModel.fromJson(response);
  }

  /// Insert a new medication.
  Future<MedicationModel> addMedication(MedicationModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .insert(model.toJson())
        .select()
        .single();

    return MedicationModel.fromJson(response);
  }

  /// Update a medication.
  Future<MedicationModel> updateMedication(MedicationModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .update(model.toJson())
        .eq('id', model.id)
        .select()
        .single();

    return MedicationModel.fromJson(response);
  }

  /// Delete a medication.
  Future<void> deleteMedication(String id) async {
    await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .delete()
        .eq('id', id);
  }

  /// Update medication quantity by delta.
  Future<MedicationModel> updateQuantity(String id, int delta) async {
    // Fetch current, update, return
    final current = await getMedicationById(id);
    final newQuantity = (current.quantity + delta).clamp(0, 999999);

    final response = await SupabaseConfig.client
        .from(AppConstants.medicationsTable)
        .update({'quantity': newQuantity})
        .eq('id', id)
        .select()
        .single();

    return MedicationModel.fromJson(response);
  }
}

