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
  });

  /// Camera + ML Kit OCR (mobile only).
  final bool hasCamera;

  /// Scheduled local notifications (mobile only; desktop plugins cannot schedule).
  final bool hasLocalNotifications;

  /// share_plus with files (everything except web).
  final bool hasFileShare;

  /// local_auth biometrics.
  final bool hasBiometrics;

  static const web = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: false,
    hasBiometrics: false,
  );
  static const mobile = PlatformCapabilities(
    hasCamera: true,
    hasLocalNotifications: true,
    hasFileShare: true,
    hasBiometrics: true,
  );
  static const desktop = PlatformCapabilities(
    hasCamera: false,
    hasLocalNotifications: false,
    hasFileShare: true,
    hasBiometrics: false,
  );

  factory PlatformCapabilities.detect() {
    if (kIsWeb) return web;
    if (Platform.isAndroid || Platform.isIOS) return mobile;
    return desktop;
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformCapabilities &&
      other.hasCamera == hasCamera &&
      other.hasLocalNotifications == hasLocalNotifications &&
      other.hasFileShare == hasFileShare &&
      other.hasBiometrics == hasBiometrics;

  @override
  int get hashCode => Object.hash(
    hasCamera,
    hasLocalNotifications,
    hasFileShare,
    hasBiometrics,
  );
}

final platformCapabilitiesProvider = Provider<PlatformCapabilities>(
  (ref) => PlatformCapabilities.detect(),
);
