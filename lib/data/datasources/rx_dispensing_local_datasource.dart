/// Medora - Rx Dispensing Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';

class RxDispensingLocalDatasource {
  RxDispensingLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<RxDispensingModel>(
        table: 'rx_dispensings',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: RxDispensingModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<RxDispensingModel> _table;

  Future<void> upsert(RxDispensingModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);

  Future<List<RxDispensingModel>> getForRx(String rxId) => _table.getAll(
    where: 'rx_id = ?',
    whereArgs: [rxId],
    orderBy: 'dispensed_on',
  );

  Future<List<RxDispensingModel>> getForRxIds(List<String> rxIds) {
    if (rxIds.isEmpty) return Future.value(const []);
    final marks = List.filled(rxIds.length, '?').join(',');
    return _table.getAll(where: 'rx_id IN ($marks)', whereArgs: rxIds);
  }

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      RxDispensingModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    RxDispensingModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      ...m.toJson(),
      ...SyncedLocalTable.rowStamps(
        m.createdAt,
        m.updatedAt,
        m.deletedAt,
        syncStatus,
        at,
      ),
    };
  }
}
