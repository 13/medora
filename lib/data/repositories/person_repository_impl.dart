/// Medora - Person Repository (offline-first).
library;

import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/person_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';

class PersonRepositoryImpl implements PersonRepository {
  PersonRepositoryImpl({
    required this.local,
    this._requestSync,
    this._now = systemNow,
  });

  final PersonLocalDatasource local;
  final RequestSync? _requestSync;
  final Now _now;

  @override
  Future<Result<List<Person>>> getPersons() async {
    try {
      final rows = await local.getPersons();
      return Result.success([for (final r in rows) r.toDomain()]);
    } catch (e, st) {
      return Result.failure('Failed to load persons: $e', st);
    }
  }

  @override
  Future<Result<Person?>> getByTaxCode(String taxCode) async {
    try {
      return Result.success((await local.getByTaxCode(taxCode))?.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to load person: $e', st);
    }
  }

  @override
  Future<Result<Person>> savePerson(Person person) async {
    try {
      final previous = await local.getPersonById(person.id);
      if (previous?.deletedAt != null) {
        return const Result.failure('Person was deleted');
      }
      final now = _now();
      final model = PersonModel.fromDomain(
        person.copyWith(
          createdAt: person.createdAt ?? previous?.createdAt ?? now,
          updatedAt: nextUpdatedAt(previous?.updatedAt, now),
        ),
      );
      await local.upsert(
        model,
        syncStatus: previous == null
            ? SyncStatus.pendingCreate
            : SyncStatus.pendingUpdate,
      );
      requestSyncSoon(_requestSync, 'person');
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to save person: $e', st);
    }
  }

  @override
  Future<Result<void>> deletePerson(String id) async {
    try {
      await local.markDeleted(id);
      requestSyncSoon(_requestSync, 'person');
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete person: $e', st);
    }
  }
}
