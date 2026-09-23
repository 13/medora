/// Medora - Person Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/person_model.dart';

class PersonLocalDatasource {
  PersonLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<PersonModel>(
        table: 'persons',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: PersonModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<PersonModel> _table;

  Future<void> upsert(PersonModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);
  Future<PersonModel?> getPersonById(String id) => _table.getById(id);
  Future<List<PersonModel>> getPersons() =>
      _table.getAll(orderBy: 'name COLLATE NOCASE');

  Future<PersonModel?> getByTaxCode(String taxCode) async {
    final rows = await _table.getAll(
      where: 'tax_code = ?',
      whereArgs: [taxCode],
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      PersonModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    PersonModel m,
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
