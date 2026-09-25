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
    required this.hasFileSystem,
    required this.hasOnDeviceScanner,
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

  /// A local file system for app files (attachments are stored as files;
  /// everything except web).
  final bool hasFileSystem;

  /// An on-device text/barcode reader (ML Kit) to scan a prescription with;
  /// true only on Android and iOS. Screens that offer scanning fall back to
  /// the plain (manual) form everywhere else, even where [hasCamera] or
  /// [hasFileSystem] is true (desktop can still pick a file, but there is no
  /// on-device reader to run over it).
  final bool hasOnDeviceScanner;

  static const web = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: false,
    hasBiometrics: false,
    hasInAppUpdates: false,
    hasSupplementRegister: false,
    hasFileSystem: false,
    hasOnDeviceScanner: false,
  );
  static const mobile = PlatformCapabilities(
    hasCamera: true,
    hasLocalNotifications: true,
    hasFileShare: true,
    hasBiometrics: true,
    hasInAppUpdates: true,
    hasSupplementRegister: true,
    hasFileSystem: true,
    hasOnDeviceScanner: true,
  );
  static const desktop = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: true,
    hasBiometrics: false,
    hasInAppUpdates: false,
    hasSupplementRegister: true,
    hasFileSystem: true,
    hasOnDeviceScanner: false,
  );

  /// Like [mobile], but iOS has no sideloading - the App Store updates the app.
  static const _ios = PlatformCapabilities(
    hasCamera: true,
    hasLocalNotifications: true,
    hasFileShare: true,
    hasBiometrics: true,
    hasInAppUpdates: false,
    hasSupplementRegister: true,
    hasFileSystem: true,
    hasOnDeviceScanner: true,
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
      other.hasSupplementRegister == hasSupplementRegister &&
      other.hasFileSystem == hasFileSystem &&
      other.hasOnDeviceScanner == hasOnDeviceScanner;

  @override
  int get hashCode => Object.hash(
    hasCamera,
    hasLocalNotifications,
    hasFileShare,
    hasBiometrics,
    hasInAppUpdates,
    hasSupplementRegister,
    hasFileSystem,
    hasOnDeviceScanner,
  );
}

final platformCapabilitiesProvider = Provider<PlatformCapabilities>(
  (ref) => PlatformCapabilities.detect(),
);
