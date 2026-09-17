/// Medora - Family Repository Implementation (Offline-First)
library;

import 'package:medora/core/clock.dart';
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
    bool Function()? isOnline,
    this._now = systemNow,
  }) : _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline);

  final FamilyLocalDatasource localDatasource;
  final FamilyRemoteDatasource? remoteDatasource;
  final bool Function() _isOnline;

  /// The clock for the times a family or a membership is created at.
  final Now _now;

  static const _uuid = Uuid();

  @override
  Future<Result<Family>> createFamily(
    String name,
    String ownerDisplayName,
  ) async {
    try {
      final inviteCode = _generateCode();
      final familyId = _uuid.v4();
      final memberId = _uuid.v4();
      final userId = SupabaseConfig.currentUserId;
      final now = _now();

      final family = FamilyModel(
        id: familyId,
        name: name,
        inviteCode: inviteCode,
        ownerId: userId,
        createdAt: now,
      );

      final member = FamilyMemberModel(
        id: memberId,
        familyId: familyId,
        userId: userId,
        displayName: ownerDisplayName,
        role: 'owner',
        joinedAt: now,
      );

      await localDatasource.upsertFamily(
        family,
        syncStatus: SyncStatus.pendingCreate,
      );
      await localDatasource.upsertMember(
        member,
        syncStatus: SyncStatus.pendingCreate,
      );

      final remote = remoteDatasource;
      if (remote != null && _isOnline()) {
        try {
          await remote.createFamily(family);
          await remote.addMember(member);
          await localDatasource.upsertFamily(
            family,
            syncStatus: SyncStatus.synced,
          );
          await localDatasource.upsertMember(
            member,
            syncStatus: SyncStatus.synced,
          );
        } catch (_) {}
      }

      return Result.success(family.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to create family: $e', st);
    }
  }

  @override
  Future<Result<Family>> joinFamily(
    String inviteCode,
    String displayName,
  ) async {
    try {
      final remote = remoteDatasource;
      if (remote == null) {
        return const Result.failure(
          'Cloud sync is required for family sharing',
        );
      }
      if (!_isOnline()) {
        return const Result.failure(
          'Internet connection required to join a family',
        );
      }

      final joined = await remote.joinFamily(inviteCode, displayName);
      await localDatasource.upsertFamily(
        joined.family,
        syncStatus: SyncStatus.synced,
      );
      await localDatasource.upsertMember(
        joined.member,
        syncStatus: SyncStatus.synced,
      );

      return Result.success(joined.family.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to join family: $e', st);
    }
  }

  @override
  Future<Result<void>> leaveFamily(String familyId) async {
    try {
      final membership = await localDatasource.getCurrentMembership();
      final remote = remoteDatasource;
      if (remote == null) {
        // Local-only mode: nothing to push, so drop the rows outright.
        if (membership != null) {
          await localDatasource.removeMember(membership.id);
        }
        await localDatasource.deleteFamily(familyId);
        return const Result.success(null);
      }
      if (membership != null) {
        await localDatasource.markMemberDeleted(membership.id);
      }
      await localDatasource.markFamilyDeleted(familyId);
      if (_isOnline() && membership != null) {
        try {
          await remote.removeMember(membership.id);
          await localDatasource.hardDeleteMember(membership.id);
          await localDatasource.deleteFamily(familyId);
        } catch (_) {
          // Left pending; the next sync pushes it.
        }
      }
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
  Future<Result<List<FamilyMember>>> getFamilyMembers(String familyId) async {
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
      final remote = remoteDatasource;
      if (remote == null) {
        return const Result.failure(
          'Cloud sync is required for family sharing',
        );
      }
      if (!_isOnline()) {
        return const Result.failure(
          'Internet connection required to regenerate code',
        );
      }
      final newCode = await remote.regenerateInviteCode(familyId);
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
      final remote = remoteDatasource;
      if (remote == null) {
        // Local-only mode: nothing to push, so drop the row outright.
        await localDatasource.removeMember(memberId);
        return const Result.success(null);
      }
      await localDatasource.markMemberDeleted(memberId);
      if (_isOnline()) {
        try {
          await remote.removeMember(memberId);
          await localDatasource.hardDeleteMember(memberId);
        } catch (_) {
          // Left pending; the next sync pushes it.
        }
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
