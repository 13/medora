/// Medora - Authentication Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase auth state. Emits a single "signed out" state when the build has
/// no Supabase configuration, so watchers never see an error.
final authStateProvider = StreamProvider<AuthState>((ref) {
  final client = SupabaseConfig.clientOrNull;
  if (client == null) {
    return Stream.value(const AuthState(AuthChangeEvent.signedOut, null));
  }
  return client.auth.onAuthStateChange;
});

/// The signed-in Supabase user, or null.
final currentUserProvider = Provider<User?>((ref) {
  final authState = ref.watch(authStateProvider).value;
  return authState?.session?.user ??
      SupabaseConfig.clientOrNull?.auth.currentUser;
});

/// Global provider for biometric lock state.
final isBiometricLockedProvider = NotifierProvider<BiometricLockNotifier, bool>(
  BiometricLockNotifier.new,
);

class BiometricLockNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setLocked(bool locked) => state = locked;
}

/// Auth actions (cloud mode only).
final authControllerProvider =
    NotifierProvider<AuthController, AsyncValue<void>>(AuthController.new);

class AuthController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<void> signInWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.signInWithPassword(
        email: email,
        password: password,
      );
    });
  }

  Future<void> signUpWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.signUp(
        email: email,
        password: password,
      );
    });
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.clientOrNull?.auth.signOut();
    });
  }
}
