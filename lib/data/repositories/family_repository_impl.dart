/// Medora - Family Repository Implementation (Offline-First)
library;

import 'package:medora/core/result.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/domain/entities/family.dart';
import 'package:medora/domain/entities/family_member.dart';
import 'package:medora/domain/repositories/family_repository.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:uuid/uuid.dart';

class FamilyRepositoryImpl implements FamilyRepository {
  FamilyRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
  });

  final FamilyLocalDatasource localDatasource;
  final FamilyRemoteDatasource remoteDatasource;

  static const _uuid = Uuid();

  @override
  Future<Result<Family>> createFamily(
      String name, String ownerDisplayName) async {
    try {
      final inviteCode = _generateCode();
      final familyId = _uuid.v4();
      final memberId = _uuid.v4();
      final userId = SupabaseConfig.currentUserId;

      final family = FamilyModel(
        id: familyId,
        name: name,
        inviteCode: inviteCode,
        ownerId: userId,
        createdAt: DateTime.now(),
      );

      final member = FamilyMemberModel(
        id: memberId,
        familyId: familyId,
        userId: userId,
        displayName: ownerDisplayName,
        role: 'owner',
        joinedAt: DateTime.now(),
      );

      await localDatasource.upsertFamily(family,
          syncStatus: SyncStatus.pendingCreate);
      await localDatasource.upsertMember(member,
          syncStatus: SyncStatus.pendingCreate);

      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.createFamily(family);
          await remoteDatasource.addMember(member);
          await localDatasource.upsertFamily(family,
              syncStatus: SyncStatus.synced);
          await localDatasource.upsertMember(member,
              syncStatus: SyncStatus.synced);
        } catch (_) {}
      }

      return Result.success(family.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to create family: $e', st);
    }
  }

  @override
  Future<Result<Family>> joinFamily(
      String inviteCode, String displayName) async {
    try {
      if (!ConnectivityService.instance.isOnline) {
        return const Result.failure(
            'Internet connection required to join a family');
      }

      final family =
          await remoteDatasource.getFamilyByInviteCode(inviteCode);
      if (family == null) {
        return const Result.failure('Invalid invite code');
      }

      final memberId = _uuid.v4();
      final member = FamilyMemberModel(
        id: memberId,
        familyId: family.id,
        userId: SupabaseConfig.currentUserId,
        displayName: displayName,
        role: 'member',
        joinedAt: DateTime.now(),
      );

      await remoteDatasource.addMember(member);
      await localDatasource.upsertFamily(family,
          syncStatus: SyncStatus.synced);
      await localDatasource.upsertMember(member,
          syncStatus: SyncStatus.synced);

      return Result.success(family.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to join family: $e', st);
    }
  }

  @override
  Future<Result<void>> leaveFamily(String familyId) async {
    try {
      final membership = await localDatasource.getCurrentMembership();
      if (membership != null) {
        await localDatasource.removeMember(membership.id);
        if (ConnectivityService.instance.isOnline) {
          try {
            await remoteDatasource.removeMember(membership.id);
          } catch (_) {}
        }
      }
      await localDatasource.deleteFamily(familyId);
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to leave family: $e', st);
    }
  }

  @override
  Future<Result<Family?>> getCurrentFamily() async {
    try {
      final family = await localDatasource.getFirstFamily();
      return Result.success(family?.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to get family: $e', st);
    }
  }

  @override
  Future<Result<List<FamilyMember>>> getFamilyMembers(
      String familyId) async {
    try {
      final members = await localDatasource.getMembers(familyId);
      return Result.success(members.map((m) => m.toDomain()).toList());
    } catch (e, st) {
      return Result.failure('Failed to get family members: $e', st);
    }
  }

  @override
  Future<Result<String>> regenerateInviteCode(String familyId) async {
    try {
      if (!ConnectivityService.instance.isOnline) {
        return const Result.failure(
            'Internet connection required to regenerate code');
      }
      final newCode = await remoteDatasource.regenerateInviteCode(familyId);
      // Update local
      final family = await localDatasource.getFamilyById(familyId);
      if (family != null) {
        await localDatasource.upsertFamily(
          FamilyModel(
            id: family.id,
            name: family.name,
            inviteCode: newCode,
            ownerId: family.ownerId,
            createdAt: family.createdAt,
          ),
          syncStatus: SyncStatus.synced,
        );
      }
      return Result.success(newCode);
    } catch (e, st) {
      return Result.failure('Failed to regenerate invite code: $e', st);
    }
  }

  @override
  Future<Result<void>> removeMember(String memberId) async {
    try {
      await localDatasource.removeMember(memberId);
      if (ConnectivityService.instance.isOnline) {
        try {
          await remoteDatasource.removeMember(memberId);
        } catch (_) {}
      }
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to remove member: $e', st);
    }
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    return List.generate(6, (i) {
      final idx = (random ~/ (i + 1) * 7 + i * 13) % chars.length;
      return chars[idx];
    }).join();
  }
}

