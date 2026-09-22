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

/// What a sign-up left behind.
enum SignUpOutcome {
  /// A session exists: the person is in, and their local rows can be claimed.
  signedIn,

  /// The account exists but needs the link in the confirmation mail first.
  confirmationRequired,

  /// Nothing was created; the controller's state carries the error.
  failed,
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

  /// Registers [email], and says whether that signed the person in.
  ///
  /// With e-mail confirmation off (how this project is configured, see
  /// `docs/superpowers/plans/2026-09-22-auth-feedback-plan.md`) Supabase
  /// returns a session straight away and the answer is
  /// [SignUpOutcome.signedIn]. With it on there is no session until the link
  /// in the mail is opened, and the caller has to say so rather than look
  /// like it did nothing — which is exactly what the screen used to do.
  Future<SignUpOutcome> signUpWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.signUp(
        email: email,
        password: password,
      );
    });
    if (state is AsyncError) return SignUpOutcome.failed;
    return SupabaseConfig.clientOrNull?.auth.currentSession == null
        ? SignUpOutcome.confirmationRequired
        : SignUpOutcome.signedIn;
  }

  /// Sends the confirmation mail again. Supabase rate-limits this per
  /// address, so the screen holds its own cooldown in front of it.
  Future<void> resendConfirmation(String email) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.resend(
        type: OtpType.signup,
        email: email,
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
