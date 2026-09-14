import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/repositories/family_repository_impl.dart';

import '../../helpers/fake_remotes.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<void> seedLocalFamily(FamilyLocalDatasource local) async {
    await local.upsertFamily(
      const FamilyModel(
        id: 'f1',
        name: 'Smith',
        inviteCode: 'ABC123',
        ownerId: 'owner',
      ),
      syncStatus: SyncStatus.synced,
    );
    await local.upsertMember(
      const FamilyMemberModel(
        id: 'me',
        familyId: 'f1',
        userId: 'user-a',
        role: 'member',
      ),
      syncStatus: SyncStatus.synced,
    );
    await local.upsertMember(
      const FamilyMemberModel(
        id: 'other',
        familyId: 'f1',
        userId: 'user-b',
        role: 'member',
      ),
      syncStatus: SyncStatus.synced,
    );
  }

  test('removeMember marks the row pending_delete while offline', () async {
    final local = FamilyLocalDatasource();
    await seedLocalFamily(local);
    final repo = FamilyRepositoryImpl(
      localDatasource: local,
      remoteDatasource: FakeFamilyRemote(DateTime.now),
      isOnline: () => false,
    );
    expect((await repo.removeMember('other')).isSuccess, isTrue);
    expect((await local.getMembers('f1')).map((m) => m.id), ['me']);
    final db = await AppDatabase.instance.database;
    final row = (await db.query(
      'family_members',
      where: 'id = ?',
      whereArgs: ['other'],
    )).single;
    expect(row['sync_status'], SyncStatus.pendingDelete);
  });

  test(
    'leaveFamily marks membership and family pending_delete; getCurrentFamily is null',
    () async {
      final local = FamilyLocalDatasource();
      await seedLocalFamily(local);
      final repo = FamilyRepositoryImpl(
        localDatasource: local,
        remoteDatasource: FakeFamilyRemote(DateTime.now),
        isOnline: () => false,
      );
      await repo.leaveFamily('f1');
      expect((await repo.getCurrentFamily()).dataOrNull, isNull);
      final db = await AppDatabase.instance.database;
      expect(
        (await db.query(
          'families',
          where: 'id = ?',
          whereArgs: ['f1'],
        )).single['sync_status'],
        SyncStatus.pendingDelete,
      );
    },
  );

  test(
    'joinFamily goes through the RPC and stores family + member locally',
    () async {
      final local = FamilyLocalDatasource();
      final remote = FakeFamilyRemote(DateTime.now, currentUserId: 'user-a');
      remote.families.seed(
        const FamilyModel(
          id: 'f9',
          name: 'Rossi',
          inviteCode: 'JOINME',
          ownerId: 'owner',
        ).toJson(),
      );
      final repo = FamilyRepositoryImpl(
        localDatasource: local,
        remoteDatasource: remote,
        isOnline: () => true,
      );
      final result = await repo.joinFamily('JOINME', 'Ben');
      expect(result.isSuccess, isTrue, reason: result.toString());
      expect((await local.getFirstFamily())?.id, 'f9');
      expect((await local.getCurrentMembership())?.userId, 'user-a');
    },
  );
}
