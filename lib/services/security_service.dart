/// Medora - Security Service
///
/// Handles the app lock (biometrics, falling back to the device credential).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// How an unlock attempt ended.
///
/// `local_auth` 3 never shows an OS error dialog of its own
/// (`useErrorDialogs` is always false), so every failure reason has to be
/// surfaced by the app or the lock screen becomes a silent dead end.
enum AuthOutcome {
  /// The user authenticated.
  success,

  /// The user dismissed the prompt, the system cancelled it, or the
  /// challenge simply failed with no side effects — retrying is sensible.
  cancelled,

  /// The device has no biometrics and no device credential enrolled.
  notEnrolled,

  /// This device cannot authenticate at all (no hardware, hardware busy, or
  /// no platform implementation — desktop and web).
  notAvailable,

  /// Temporarily locked out after too many attempts; retrying later works.
  lockedOut,

  /// Locked out until authentication succeeds elsewhere — the app cannot
  /// resolve this on its own.
  permanentlyLockedOut,

  /// Any other device-level or unexpected error.
  error;

  /// True when retrying inside the app can never succeed: the lock has to
  /// offer a way out or the setting becomes unusable.
  bool get isUnrecoverable =>
      this == AuthOutcome.notEnrolled ||
      this == AuthOutcome.notAvailable ||
      this == AuthOutcome.permanentlyLockedOut;
}

class SecurityService {
  SecurityService._();
  static final SecurityService instance = SecurityService._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// Check if biometrics are available on the device.
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('SecurityService: error checking availability: $e');
      return false;
    }
  }

  /// Trigger authentication, reporting *why* it did not succeed.
  Future<AuthOutcome> authenticate({String reason = 'Unlock Medora'}) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
        // Spec F11: device credentials (PIN, pattern, passcode) are accepted,
        // which is `biometricOnly`'s default and so cannot be passed
        // explicitly (avoid_redundant_argument_values). `biometricOnly: true`
        // would lock out every device whose owner only has a screen lock,
        // with no way back in.
      );
      // `false` means the challenge failed without side effects (the user
      // walked away, a bad fingerprint): the same affordance as a cancel.
      return ok ? AuthOutcome.success : AuthOutcome.cancelled;
    } on LocalAuthException catch (e) {
      debugPrint(
        'SecurityService: auth error: ${e.code.name} ${e.description}',
      );
      return _outcomeFor(e.code);
    } on PlatformException catch (e) {
      debugPrint('SecurityService: auth error: $e');
      return AuthOutcome.error;
    } on MissingPluginException catch (e) {
      // Desktop and web have no implementation of the plugin.
      debugPrint('SecurityService: auth unavailable: $e');
      return AuthOutcome.notAvailable;
    }
  }

  /// New codes may be added to [LocalAuthExceptionCode] without a breaking
  /// change, so this deliberately falls through to [AuthOutcome.error].
  static AuthOutcome _outcomeFor(LocalAuthExceptionCode code) => switch (code) {
    LocalAuthExceptionCode.userCanceled ||
    LocalAuthExceptionCode.systemCanceled ||
    LocalAuthExceptionCode.timeout ||
    LocalAuthExceptionCode.userRequestedFallback => AuthOutcome.cancelled,
    LocalAuthExceptionCode.noCredentialsSet ||
    LocalAuthExceptionCode.noBiometricsEnrolled => AuthOutcome.notEnrolled,
    LocalAuthExceptionCode.noBiometricHardware ||
    LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
    LocalAuthExceptionCode.uiUnavailable => AuthOutcome.notAvailable,
    LocalAuthExceptionCode.temporaryLockout => AuthOutcome.lockedOut,
    // Biometrics stay locked until some *other* authentication succeeds,
    // which has to happen outside this app.
    LocalAuthExceptionCode.biometricLockout => AuthOutcome.permanentlyLockedOut,
    _ => AuthOutcome.error,
  };
}
