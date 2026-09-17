/// Medora - Dose Log Remote Datasource
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/pull_page.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/sync/push_settle.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DoseLogRemoteDatasource {
  DoseLogRemoteDatasource(SupabaseClient client)
    : _client = client,
      rows = PostgrestSyncTable(
        client,
        AppConstants.doseLogsTable,
        select: '*, prescriptions(id, medications(name))',
      );

  /// The `dose_logs` rows (sync v2).
  final SyncTable rows;

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

  /// One page of the rows changed after [since] (UTC; all rows when null),
  /// tombstones included: the rows after [after] in the pull order, at most
  /// [pullPageSize] of them. See `pullPage`.
  Future<List<DoseLogModel>> getDoseLogsSince(
    DateTime? since, {
    PullKey? after,
  }) async {
    final response = await pullPage(
      _client
          .from(AppConstants.doseLogsTable)
          .select('*, prescriptions(id, medications(name))'),
      since: since,
      after: after,
    );
    return response.map(DoseLogModel.fromJson).toList();
  }

  /// The remote row's `updated_at`, or null when the row is not there.
  ///
  /// The push phase uses it to leave a remote row alone when it is newer than
  /// the local pending edit (true last-write-wins).
  Future<DateTime?> getUpdatedAt(String id) async {
    final response = await _client
        .from(AppConstants.doseLogsTable)
        .select('updated_at')
        .eq('id', id)
        .maybeSingle();
    final raw = response?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// The single row with [id], or null when the server does not have it.
  Future<DoseLogModel?> getDoseLogById(String id) async {
    final response = await _client
        .from(AppConstants.doseLogsTable)
        .select('*, prescriptions(id, medications(name))')
        .eq('id', id)
        .maybeSingle();

    return response == null ? null : DoseLogModel.fromJson(response);
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

  /// Upsert a dose log (insert or update). Returns the `updated_at` the
  /// server gave this write (see `settlePushedRow`). An answer without the
  /// written row is an error, so the row stays pending.
  Future<DateTime?> upsertDoseLog(DoseLogModel model) async {
    final response = await _client
        .from(AppConstants.doseLogsTable)
        .upsert(model.toJson())
        .select('updated_at')
        .single();
    return serverStampOf(response);
  }

  /// Inserts [models] in one request, leaving every row the server already
  /// has untouched (`ON CONFLICT (id) DO NOTHING`).
  ///
  /// This is how a dose this device created reaches the server: a dose with
  /// a deterministic id may already be there, taken or skipped on another
  /// device, and a generated copy must never replace it. The answer carries
  /// no rows; read them back with [getDoseLogsByIds].
  Future<void> insertDoseLogsIfAbsent(List<DoseLogModel> models) async {
    if (models.isEmpty) return;
    await _client
        .from(AppConstants.doseLogsTable)
        .upsert(
          [for (final m in models) m.toJson()],
          onConflict: 'id',
          ignoreDuplicates: true,
        );
  }

  /// The server's rows with these [ids], tombstones included. Ids the server
  /// does not have are simply absent from the list.
  Future<List<DoseLogModel>> getDoseLogsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final response = await _client
        .from(AppConstants.doseLogsTable)
        .select()
        .inFilter('id', ids);
    return (response as List)
        .map((json) => DoseLogModel.fromJson(json as Map<String, dynamic>))
        .toList();
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
