/// Medora - Security Service
///
/// Handles biometric authentication (fingerprint/face).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

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

  /// Trigger biometric authentication.
  Future<bool> authenticate({String reason = 'Unlock Medora'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } on PlatformException catch (e) {
      debugPrint('SecurityService: auth error: $e');
      return false;
    }
  }
}
