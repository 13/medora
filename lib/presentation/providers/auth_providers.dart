/// Medora - Authentication Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider for the Supabase Auth state.
final authStateProvider = StreamProvider<AuthState>((ref) {
  return SupabaseConfig.client.auth.onAuthStateChange;
});

/// Provider for the current user.
final currentUserProvider = Provider<User?>((ref) {
  final authState = ref.watch(authStateProvider).value;
  return authState?.session?.user ?? SupabaseConfig.client.auth.currentUser;
});

/// Provider for Offline Mode.
final isOfflineModeProvider = NotifierProvider<OfflineModeNotifier, bool>(OfflineModeNotifier.new);

class OfflineModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// Global provider for biometric lock state.
/// This prevents triggering re-authentication on every sub-route navigation.
final isBiometricLockedProvider = NotifierProvider<BiometricLockNotifier, bool>(BiometricLockNotifier.new);

class BiometricLockNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setLocked(bool locked) => state = locked;
}

/// Notifier for Auth actions.
final authControllerProvider = NotifierProvider<AuthController, AsyncValue<void>>(AuthController.new);

class AuthController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<void> signInWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      ref.read(isOfflineModeProvider.notifier).set(false);
    });
  }

  Future<void> signUpWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.client.auth.signUp(
        email: email,
        password: password,
      );
      ref.read(isOfflineModeProvider.notifier).set(false);
    });
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.client.auth.signOut();
      ref.read(isOfflineModeProvider.notifier).set(false);
    });
  }

  Future<void> signInAnonymously() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.client.auth.signInAnonymously();
      ref.read(isOfflineModeProvider.notifier).set(false);
    });
  }

  void enterOfflineMode() {
    ref.read(isOfflineModeProvider.notifier).set(true);
  }
}
