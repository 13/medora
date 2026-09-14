/// Medora - Family Remote Datasource (Supabase)
library;

import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FamilyRemoteDatasource {
  FamilyRemoteDatasource(this._client);

  final SupabaseClient _client;

  Future<FamilyModel> createFamily(FamilyModel family) async {
    final response = await _client
        .from('families')
        .insert(family.toJson())
        .select()
        .single();
    return FamilyModel.fromJson(response);
  }

  Future<void> upsertFamily(FamilyModel family) async {
    await _client.from('families').upsert(family.toJson());
  }

  Future<void> upsertMember(FamilyMemberModel member) async {
    await _client.from('family_members').upsert(member.toJson());
  }

  /// Joins via the `join_family` RPC (security definer; see the 2026-09-14
  /// migration) so a non-owner can join without a SELECT policy on families.
  Future<({FamilyModel family, FamilyMemberModel member})> joinFamily(
    String inviteCode,
    String displayName,
  ) async {
    final response =
        await _client.rpc(
              'join_family',
              params: {
                'p_invite_code': inviteCode,
                'p_display_name': displayName,
              },
            )
            as Map<String, dynamic>;
    return (
      family: FamilyModel.fromJson(response['family'] as Map<String, dynamic>),
      member: FamilyMemberModel.fromJson(
        response['member'] as Map<String, dynamic>,
      ),
    );
  }

  Future<FamilyModel?> getFamilyByInviteCode(String code) async {
    final response = await _client
        .from('families')
        .select()
        .eq('invite_code', code)
        .maybeSingle();
    if (response == null) return null;
    return FamilyModel.fromJson(response);
  }

  Future<FamilyModel?> getFamilyById(String id) async {
    final response = await _client
        .from('families')
        .select()
        .eq('id', id)
        .maybeSingle();
    if (response == null) return null;
    return FamilyModel.fromJson(response);
  }

  Future<FamilyMemberModel> addMember(FamilyMemberModel member) async {
    final response = await _client
        .from('family_members')
        .insert(member.toJson())
        .select()
        .single();
    return FamilyMemberModel.fromJson(response);
  }

  Future<List<FamilyMemberModel>> getMembers(String familyId) async {
    final response = await _client
        .from('family_members')
        .select()
        .eq('family_id', familyId)
        .order('joined_at');
    return (response as List)
        .map((e) => FamilyMemberModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> removeMember(String memberId) async {
    await _client.from('family_members').delete().eq('id', memberId);
  }

  Future<FamilyMemberModel?> getCurrentMembership() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final response = await _client
        .from('family_members')
        .select()
        .eq('user_id', userId)
        .order('joined_at')
        .limit(1)
        .maybeSingle();
    if (response == null) return null;
    return FamilyMemberModel.fromJson(response);
  }

  Future<String> regenerateInviteCode(String familyId) async {
    final newCode = _generateCode();
    await _client
        .from('families')
        .update({'invite_code': newCode})
        .eq('id', familyId);
    return newCode;
  }

  Future<void> deleteFamily(String familyId) async {
    await _client.from('families').delete().eq('id', familyId);
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
