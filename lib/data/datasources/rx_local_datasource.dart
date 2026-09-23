/// Medora - Rx Local Datasource
library;

import 'dart:convert';

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/rx_model.dart';

class RxLocalDatasource {
  RxLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<RxModel>(
        table: 'rx',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: RxModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<RxModel> _table;

  Future<void> upsert(RxModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);
  Future<void> hardDelete(String id) => _table.hardDelete(id);
  Future<RxModel?> getById(String id) => _table.getById(id);

  /// Every live prescription, newest issue first.
  Future<List<RxModel>> getAll() =>
      _table.getAll(orderBy: 'issued_on DESC, created_at DESC');

  Future<RxModel?> getByNre(String nre) async {
    final rows = await _table.getAll(where: 'nre = ?', whereArgs: [nre]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<RxModel>> getForTreatment(String treatmentId) => _table.getAll(
    where: 'treatment_id = ?',
    whereArgs: [treatmentId],
    orderBy: 'issued_on DESC',
  );

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      RxModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    RxModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    final wire = m.toJson();
    return {
      ...wire,
      'items': jsonEncode(wire['items']),
      'cancelled': m.cancelled ? 1 : 0,
      'created_at': (m.createdAt ?? at).toIso8601String(),
      'updated_at': (m.updatedAt ?? at).toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      ...SyncedLocalTable.pendingStamp(syncStatus, m.updatedAt, at),
    };
  }
}
