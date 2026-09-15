import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/widgets/update_banner.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_update_service.dart';
import '../../helpers/pump_app.dart';

void main() {
  late Directory root;
  final clock = DateTime.utc(2026, 3, 4, 15);

  setUp(() {
    root = Directory.systemTemp.createTempSync('medora_update_banner');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(dynamic, FakeUpdateService)> pumpBanner(
    WidgetTester tester, {
    ReleaseVersion latest = const ReleaseVersion(0, 2, 0, 12),
  }) async {
    final service = FakeUpdateService(release: fakeRelease(latest));
    final container = await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateBanner()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
      ),
    );
    return (container, service);
  }

  testWidgets('nothing is rendered before a check', (tester) async {
    await pumpBanner(tester);
    await tester.pumpAndSettle();

    expect(find.byType(SizedBox), findsWidgets);
    expect(find.text('View'), findsNothing);
  });

  testWidgets('an available update is announced with View and dismiss', (
    tester,
  ) async {
    final (container, _) = await pumpBanner(tester);
    await container.read(appUpdateProvider.notifier).check();
    await tester.pumpAndSettle();

    expect(find.text('Medora v0.2.0 is available'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
  });

  testWidgets('dismissing hides the banner and persists the tag', (
    tester,
  ) async {
    final (container, _) = await pumpBanner(tester);
    await container.read(appUpdateProvider.notifier).check();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Medora v0.2.0 is available'), findsNothing);
    expect(container.read(updateDismissedTagProvider), 'v0.2.0+12');
  });

  testWidgets('a banner dismissed in an earlier session stays hidden', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({kUpdateDismissedTag: 'v0.2.0+12'});
    final (container, _) = await pumpBanner(tester);
    await container.read(appUpdateProvider.notifier).check();
    await tester.pumpAndSettle();

    expect(find.text('Medora v0.2.0 is available'), findsNothing);
  });

  testWidgets('an up-to-date app shows no banner', (tester) async {
    final (container, _) = await pumpBanner(tester, latest: fakeCurrentVersion);
    await container.read(appUpdateProvider.notifier).check();
    await tester.pumpAndSettle();

    expect(find.text('View'), findsNothing);
  });

  testWidgets('an empty UPDATE_REPO renders nothing, release or not', (
    tester,
  ) async {
    final service = FakeUpdateService(
      release: fakeRelease(const ReleaseVersion(0, 2, 0, 12)),
    );
    final container = await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateBanner()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
        repo: '',
      ),
    );
    await container.read(appUpdateProvider.notifier).check(force: true);
    await tester.pumpAndSettle();

    expect(find.text('View'), findsNothing);
    expect(service.checks, 0);
  });
}
