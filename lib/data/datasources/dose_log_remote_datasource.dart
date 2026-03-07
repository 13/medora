/// Medora - Dose Log Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/models/dose_log_model.dart';

class DoseLogRemoteDatasource {
  DoseLogRemoteDatasource();

  Future<List<DoseLogModel>> getDoseLogsByPrescription(
    String prescriptionId,
  ) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(dosage, medications(name))')
        .eq('prescription_id', prescriptionId)
        .order('scheduled_time');

    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<DoseLogModel>> getTodaysDoseLogs() async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final response = await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(dosage, medications(name))')
        .gte('scheduled_time', startOfDay.toIso8601String())
        .lt('scheduled_time', endOfDay.toIso8601String())
        .order('scheduled_time');

    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<DoseLogModel>> getDoseLogsByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(dosage, medications(name))')
        .gte('scheduled_time', start.toIso8601String())
        .lt('scheduled_time', end.toIso8601String())
        .order('scheduled_time');

    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<DoseLogModel> addDoseLog(DoseLogModel model) async {
    final response = await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .insert(model.toJson())
        .select('*, prescriptions(dosage, medications(name))')
        .single();

    return DoseLogModel.fromJson(response);
  }

  Future<DoseLogModel> updateDoseLogStatus(
    String id,
    String status, {
    DateTime? takenTime,
  }) async {
    final updates = <String, dynamic>{'status': status};
    if (takenTime != null) {
      updates['taken_time'] = takenTime.toIso8601String();
    }

    final response = await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .update(updates)
        .eq('id', id)
        .select('*, prescriptions(dosage, medications(name))')
        .single();

    return DoseLogModel.fromJson(response);
  }

  Future<void> addDoseLogsBatch(List<DoseLogModel> models) async {
    final jsonList = models.map((m) => m.toJson()).toList();
    await SupabaseConfig.client
        .from(AppConstants.doseLogsTable)
        .insert(jsonList);
  }
}

