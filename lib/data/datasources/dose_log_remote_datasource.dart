/// Medora - Dose Log Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DoseLogRemoteDatasource {
  DoseLogRemoteDatasource(this._client);

  final SupabaseClient _client;

  Future<List<DoseLogModel>> getDoseLogs() async {
    final response = await _client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(id, medications(name)) ')
        .isFilter('deleted_at', null);

    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Rows changed after [since] (UTC); all rows when null. Includes tombstones.
  Future<List<DoseLogModel>> getDoseLogsSince(DateTime? since) async {
    final base = _client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(id, medications(name))');
    final filtered = since == null
        ? base
        : base.gt('updated_at', since.toUtc().toIso8601String());
    final response = await filtered.order('updated_at');
    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<List<DoseLogModel>> getTodaysDoseLogs() async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final response = await _client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(id, medications(name))')
        .gte('scheduled_time', startOfDay.toIso8601String())
        .lt('scheduled_time', endOfDay.toIso8601String())
        .isFilter('deleted_at', null);

    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<void> addDoseLog(DoseLogModel model) async {
    await _client.from(AppConstants.doseLogsTable).insert(model.toJson());
  }

  Future<void> addDoseLogsBatch(List<DoseLogModel> models) async {
    if (models.isEmpty) return;
    await _client
        .from(AppConstants.doseLogsTable)
        .insert(models.map((m) => m.toJson()).toList());
  }

  Future<void> upsertDoseLog(DoseLogModel model) async {
    await _client.from(AppConstants.doseLogsTable).upsert(model.toJson());
  }

  /// Update dose log status.
  Future<void> updateDoseLogStatus(
    String id,
    String status, {
    DateTime? takenTime,
  }) async {
    final Map<String, dynamic> updateData = {
      'status': status,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (takenTime != null) {
      updateData['taken_time'] = takenTime.toUtc().toIso8601String();
    } else if (status == 'pending') {
      updateData['taken_time'] = null;
    }

    await _client
        .from(AppConstants.doseLogsTable)
        .update(updateData)
        .eq('id', id);
  }

  /// Delete a dose log from remote.
  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deleteDoseLog(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.doseLogsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }
}
