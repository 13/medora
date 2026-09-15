/// Medora - Platform capability flags.
///
/// Screens read these instead of sprinkling `kIsWeb` / `Platform.isX` checks.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.hasCamera,
    required this.hasLocalNotifications,
    required this.hasFileShare,
    required this.hasBiometrics,
    required this.hasInAppUpdates,
    required this.hasSupplementRegister,
  });

  /// Camera + ML Kit OCR (mobile only).
  final bool hasCamera;

  /// Scheduled local notifications (mobile only; desktop plugins cannot schedule).
  final bool hasLocalNotifications;

  /// share_plus with files (everything except web).
  final bool hasFileShare;

  /// local_auth biometrics.
  final bool hasBiometrics;

  /// Downloading and installing an APK from GitHub Releases (Android only).
  final bool hasInAppUpdates;

  /// The offline food-supplement register (gzip download into a file-backed
  /// SQLite database; everything except web).
  final bool hasSupplementRegister;

  static const web = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: false,
    hasBiometrics: false,
    hasInAppUpdates: false,
    hasSupplementRegister: false,
  );
  static const mobile = PlatformCapabilities(
    hasCamera: true,
    hasLocalNotifications: true,
    hasFileShare: true,
    hasBiometrics: true,
    hasInAppUpdates: true,
    hasSupplementRegister: true,
  );
  static const desktop = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: true,
    hasBiometrics: false,
    hasInAppUpdates: false,
    hasSupplementRegister: true,
  );

  /// Like [mobile], but iOS has no sideloading - the App Store updates the app.
  static const _ios = PlatformCapabilities(
    hasCamera: true,
    hasLocalNotifications: true,
    hasFileShare: true,
    hasBiometrics: true,
    hasInAppUpdates: false,
    hasSupplementRegister: true,
  );

  factory PlatformCapabilities.detect() {
    if (kIsWeb) return web;
    if (Platform.isAndroid) return mobile;
    if (Platform.isIOS) return _ios;
    return desktop;
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformCapabilities &&
      other.hasCamera == hasCamera &&
      other.hasLocalNotifications == hasLocalNotifications &&
      other.hasFileShare == hasFileShare &&
      other.hasBiometrics == hasBiometrics &&
      other.hasInAppUpdates == hasInAppUpdates &&
      other.hasSupplementRegister == hasSupplementRegister;

  @override
  int get hashCode => Object.hash(
    hasCamera,
    hasLocalNotifications,
    hasFileShare,
    hasBiometrics,
    hasInAppUpdates,
    hasSupplementRegister,
  );
}

final platformCapabilitiesProvider = Provider<PlatformCapabilities>(
  (ref) => PlatformCapabilities.detect(),
);
