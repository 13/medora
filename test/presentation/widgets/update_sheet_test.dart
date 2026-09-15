import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/widgets/update_sheet.dart';
import 'package:medora/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_update_service.dart';
import '../../helpers/pump_app.dart';

void main() {
  late Directory root;
  final clock = DateTime.utc(2026, 3, 4, 15);

  setUp(() {
    root = Directory.systemTemp.createTempSync('medora_update_sheet');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(dynamic, FakeUpdateService)> pumpSheet(
    WidgetTester tester, {
    UpdateException? downloadError,
  }) async {
    final service = FakeUpdateService(
      release: fakeRelease(const ReleaseVersion(0, 2, 0, 12)),
      downloadError: downloadError,
    );
    final container = await pumpMedoraApp(
      tester,
      const Scaffold(body: UpdateSheet()),
      overrides: await updateOverrides(
        service: service,
        downloadDir: root,
        now: () => clock,
      ),
    );
    await container.read(appUpdateProvider.notifier).check();
    await tester.pumpAndSettle();
    return (container, service);
  }

  testWidgets('Download leads to Install, which hands over the file', (
    tester,
  ) async {
    final (_, service) = await pumpSheet(tester);

    expect(find.text('Medora 0.2.0 (12)'), findsOneWidget);
    expect(find.text('Released Mar 1, 2026'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Fixed the thing.'), findsOneWidget);
    expect(find.text('Install'), findsNothing);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Download'), findsNothing);

    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(service.installed, hasLength(1));
  });

  testWidgets('Later dismisses the release', (tester) async {
    final (container, _) = await pumpSheet(tester);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(container.read(updateDismissedTagProvider), 'v0.2.0+12');
  });

  testWidgets('a checksum failure is explained', (tester) async {
    await pumpSheet(
      tester,
      downloadError: const UpdateException(
        UpdateErrorKind.checksum,
        'bad hash',
      ),
    );

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(find.text('The download could not be verified'), findsOneWidget);
  });
}
