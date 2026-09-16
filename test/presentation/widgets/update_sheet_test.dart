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
    String notes = 'Fixed the thing.',
  }) async {
    final service = FakeUpdateService(
      release: fakeRelease(const ReleaseVersion(0, 2, 0, 12), notes: notes),
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

    // The system installer is explained before it opens.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text(
        'Android will ask you to allow Medora to install apps, then open '
        'the installer. Your data stays on the device.',
      ),
      findsOneWidget,
    );
    expect(service.installed, isEmpty);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(service.installed, hasLength(1));
  });

  testWidgets('cancelling the explanation installs nothing', (tester) async {
    final (_, service) = await pumpSheet(tester);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(service.installed, isEmpty);
    // Still offered: the sheet is unchanged behind the dialog.
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a download in flight offers Cancel, which undoes it', (
    tester,
  ) async {
    final (container, _) = await pumpSheet(tester);

    await tester.tap(find.text('Download'));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Cancel download'), findsOneWidget);
    expect(find.text('Later'), findsNothing);

    await tester.tap(find.text('Cancel download'));
    await tester.pumpAndSettle();

    expect(container.read(appUpdateProvider).value, isA<UpdateAvailable>());
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Download'), findsOneWidget);
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

  // A body shaped like a real GitHub release: a heading, a bold bullet, and
  // more text than the sheet is willing to show at once.
  final longNotes = '## Fixed\n- **Scanner** reads the code\n${'x' * 600}';

  testWidgets('markdown notes are shown as readable text, collapsed at first', (
    tester,
  ) async {
    await pumpSheet(tester, notes: longNotes);

    expect(find.text("What's new"), findsOneWidget);
    // The heading kept its words without the '#', the bullet without the '**'.
    expect(
      find.textContaining('Fixed\n\u2022 Scanner reads the code'),
      findsOneWidget,
    );
    expect(find.textContaining('**'), findsNothing);
    // Cut short, and the way to see the rest is offered.
    expect(find.textContaining('x' * 600), findsNothing);
    expect(find.text('Show more'), findsOneWidget);
    expect(find.text('Show less'), findsNothing);
  });

  testWidgets('Show more reveals the rest and becomes Show less', (
    tester,
  ) async {
    await pumpSheet(tester, notes: longNotes);

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.textContaining('x' * 600), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets("a release with no body shows no What's new at all", (
    tester,
  ) async {
    await pumpSheet(tester, notes: '');

    expect(find.text("What's new"), findsNothing);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('notes short enough to fit are shown whole, with no toggle', (
    tester,
  ) async {
    await pumpSheet(tester);

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Fixed the thing.'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });
}
