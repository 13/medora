/// Medora - Family Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/family.dart';
import 'package:medora/domain/entities/family_member.dart';

abstract class FamilyRepository {
  Future<Result<Family>> createFamily(String name, String ownerDisplayName);
  Future<Result<Family>> joinFamily(String inviteCode, String displayName);
  Future<Result<void>> leaveFamily(String familyId);
  Future<Result<Family?>> getCurrentFamily();
  Future<Result<List<FamilyMember>>> getFamilyMembers(String familyId);
  Future<Result<String>> regenerateInviteCode(String familyId);
  Future<Result<void>> removeMember(String memberId);
}

