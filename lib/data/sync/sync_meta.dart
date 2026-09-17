/// Medora - A synced row's local bookkeeping (sync v2).
///
/// Next to its data, every local row of the four synced tables keeps:
/// - `edited_at`: when its last change was made here (1970 for a change the
///   app made on its own);
/// - `field_edited_at`: when each column was last changed ([FieldTimes]);
/// - `sync_version` and `sync_base`: the server's `row_version` and the
///   canonical copy of the server row this device was last in step with,
///   the base of every merge;
/// - `sync_write_id`: the write attempt whose answer never arrived.
library;

import 'dart:convert';

import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

/// The tables sync v2 merges, in foreign-key order.
const syncedTables = [
  'medications',
  'treatments',
  'prescriptions',
  'dose_logs',
];

/// The bookkeeping columns of a synced local row.
const syncMetaColumnNames = [
  'edited_at',
  'field_edited_at',
  'sync_version',
  'sync_base',
  'sync_write_id',
];

/// The canonical wire copy of [json], a server row: its model's `toJson`, so
/// two copies with equal content compare equal whatever format each side
/// wrote its timestamps in.
Map<String, Object?> canonicalWire(String table, Map<String, dynamic> json) =>
    switch (table) {
      'medications' => MedicationModel.fromJson(json).toJson(),
      'treatments' => TreatmentModel.fromJson(json).toJson(),
      'prescriptions' => PrescriptionModel.fromJson(json).toJson(),
      'dose_logs' => DoseLogModel.fromJson(json).toJson(),
      _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
    };

/// The wire copy of the local row [row]. [userId] fills `user_id` on the
/// tables that carry it.
Map<String, Object?> localWire(
  String table,
  Map<String, Object?> row, {
  String? userId,
}) => switch (table) {
  'medications' => MedicationModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'treatments' => TreatmentModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'prescriptions' => PrescriptionModel.fromLocalMap(row).toJson(),
  'dose_logs' => DoseLogModel.fromLocalMap(row).toJson(),
  _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
};

/// The local row (data columns and `sync_status`) for the server row
/// [json].
Map<String, Object?> localRowOf(
  String table,
  Map<String, dynamic> json,
  String syncStatus,
) => switch (table) {
  'medications' => MedicationLocalDatasource.rowOf(
    MedicationModel.fromJson(json),
    syncStatus,
  ),
  'treatments' => TreatmentLocalDatasource.rowOf(
    TreatmentModel.fromJson(json),
    syncStatus,
  ),
  'prescriptions' => PrescriptionLocalDatasource.rowOf(
    PrescriptionModel.fromJson(json),
    syncStatus,
  ),
  'dose_logs' => DoseLogLocalDatasource.rowOf(
    DoseLogModel.fromJson(json),
    syncStatus,
  ),
  _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
};

/// When each column of the local row [row] was last changed; an empty map
/// stands for the row's own time ([localRowTime]).
FieldTimes localFieldTimes(Map<String, Object?> row) =>
    FieldTimes.decode(row['field_edited_at'], rowTime: localRowTime(row));

/// The bookkeeping of one local row.
class LocalSyncMeta {
  const LocalSyncMeta({this.version, this.base, this.writeId, this.editedAt});

  factory LocalSyncMeta.fromRow(Map<String, Object?> row) {
    final rawBase = row['sync_base'] as String?;
    final rawEdited = row['edited_at'] as String?;
    return LocalSyncMeta(
      version: row['sync_version'] as int?,
      base: rawBase == null
          ? null
          : (jsonDecode(rawBase) as Map<String, dynamic>),
      writeId: row['sync_write_id'] as String?,
      editedAt: rawEdited == null ? null : DateTime.tryParse(rawEdited),
    );
  }

  final int? version;
  final Map<String, Object?>? base;
  final String? writeId;
  final DateTime? editedAt;
}

/// The bookkeeping columns for a row now in step with the server row
/// [version] / [base]. [editedAt] and [fieldTimes] are written only when
/// given.
Map<String, Object?> syncMetaValues({
  required int? version,
  required Map<String, Object?>? base,
  String? writeId,
  DateTime? editedAt,
  FieldTimes? fieldTimes,
}) => {
  'sync_version': version,
  'sync_base': base == null ? null : jsonEncode(base),
  'sync_write_id': writeId,
  if (editedAt != null) 'edited_at': editedAt.toUtc().toIso8601String(),
  if (fieldTimes != null) 'field_edited_at': fieldTimes.encode(),
};

/// The bookkeeping columns cleared: nothing is known about the server copy.
const Map<String, Object?> clearedSyncMeta = {
  'sync_version': null,
  'sync_base': null,
  'sync_write_id': null,
};
