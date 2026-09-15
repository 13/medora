import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';

void main() {
  test('presets are internally consistent', () {
    expect(PlatformCapabilities.web.hasCamera, isFalse);
    expect(PlatformCapabilities.web.hasFileShare, isFalse);
    expect(PlatformCapabilities.mobile.hasCamera, isTrue);
    expect(PlatformCapabilities.mobile.hasLocalNotifications, isTrue);
    expect(PlatformCapabilities.desktop.hasCamera, isFalse);
    expect(PlatformCapabilities.desktop.hasFileShare, isTrue);
  });

  test('only the mobile (Android) preset offers in-app updates', () {
    expect(PlatformCapabilities.mobile.hasInAppUpdates, isTrue);
    expect(PlatformCapabilities.web.hasInAppUpdates, isFalse);
    expect(PlatformCapabilities.desktop.hasInAppUpdates, isFalse);
  });

  test('detect() on the test host (Linux) yields the desktop preset', () {
    expect(PlatformCapabilities.detect(), PlatformCapabilities.desktop);
  });
}
