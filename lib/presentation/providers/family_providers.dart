/// Medora - Family Providers
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/family.dart';
import 'package:medora/domain/entities/family_member.dart';
import 'package:medora/presentation/providers/providers.dart';

// ── Current family provider ──────────────────────────────────

final currentFamilyProvider =
    AsyncNotifierProvider<CurrentFamilyNotifier, Family?>(
      CurrentFamilyNotifier.new,
    );

class CurrentFamilyNotifier extends AsyncNotifier<Family?> {
  @override
  Future<Family?> build() async {
    final repo = ref.watch(familyRepositoryProvider);
    final result = await repo.getCurrentFamily();
    return result.when(success: (family) => family, failure: (_, [_]) => null);
  }

  Future<void> createFamily(String name, String displayName) async {
    state = const AsyncValue.loading();
    final repo = ref.read(familyRepositoryProvider);
    final result = await repo.createFamily(name, displayName);
    state = result.when(
      success: AsyncValue.data,
      failure: (msg, [_]) => AsyncValue.error(msg, StackTrace.current),
    );
  }

  Future<void> joinFamily(String inviteCode, String displayName) async {
    state = const AsyncValue.loading();
    final repo = ref.read(familyRepositoryProvider);
    final result = await repo.joinFamily(inviteCode, displayName);
    state = result.when(
      success: AsyncValue.data,
      failure: (msg, [_]) => AsyncValue.error(msg, StackTrace.current),
    );
  }

  Future<void> leaveFamily() async {
    final family = state.value;
    if (family == null) return;
    state = const AsyncValue.loading();
    final repo = ref.read(familyRepositoryProvider);
    await repo.leaveFamily(family.id);
    state = const AsyncValue.data(null);
  }

  Future<void> regenerateCode() async {
    final family = state.value;
    if (family == null) return;
    final repo = ref.read(familyRepositoryProvider);
    final result = await repo.regenerateInviteCode(family.id);
    result.when(
      success: (newCode) {
        state = AsyncValue.data(family.copyWith(inviteCode: newCode));
      },
      failure: (_, [_]) {},
    );
  }

  void refresh() => ref.invalidateSelf();
}

// ── Family members provider ──────────────────────────────────

final familyMembersProvider = FutureProvider.family<List<FamilyMember>, String>(
  (ref, familyId) async {
    final repo = ref.watch(familyRepositoryProvider);
    final result = await repo.getFamilyMembers(familyId);
    return result.when(success: (members) => members, failure: (_, [_]) => []);
  },
);
