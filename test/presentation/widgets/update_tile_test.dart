import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/widgets/update_tile.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_update_service.dart';
import '../../helpers/pump_app.dart';

void main() {
  late Directory root;
  final clock = DateTime.utc(2026, 3, 4, 15);

  setUp(() {
    root = Directory.systemTemp.createTempSync('medora_update_tile');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(dynamic, FakeUpdateService)> pumpTile(
    WidgetTester tester, {
    ReleaseVersion latest = const ReleaseVersion(0, 2, 0, 12),
    PlatformCapabilities caps = PlatformCapabilities.mobile,
  }) async {
    final service = FakeUpdateService(release: fakeRelease(latest));
    final container = await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateTile()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
        caps: caps,
      ),
    );
    await tester.pumpAndSettle();
    return (container, service);
  }

  testWidgets('offers a check before anything is known', (tester) async {
    await pumpTile(tester);

    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
  });

  testWidgets('tapping it checks and reports up to date', (tester) async {
    final (_, service) = await pumpTile(tester, latest: fakeCurrentVersion);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(service.checks, 1);
    expect(find.text('Up to date'), findsOneWidget);
  });

  testWidgets('a newer release is named in the subtitle', (tester) async {
    await pumpTile(tester);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('Update available: 0.2.0 (12)'), findsOneWidget);
  });

  testWidgets('a failed check is reported', (tester) async {
    final service = FakeUpdateService(
      error: const UpdateException(UpdateErrorKind.network, 'no route'),
    );
    await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateTile()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('Could not check for updates'), findsOneWidget);
  });

  testWidgets('a platform without in-app updates renders nothing', (
    tester,
  ) async {
    await pumpTile(tester, caps: PlatformCapabilities.desktop);

    expect(find.text('Check for updates'), findsNothing);
  });

  testWidgets('an empty UPDATE_REPO renders nothing', (tester) async {
    final service = FakeUpdateService(
      release: fakeRelease(const ReleaseVersion(0, 2, 0, 12)),
    );
    await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateTile()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
        repo: '',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Check for updates'), findsNothing);
  });
}
