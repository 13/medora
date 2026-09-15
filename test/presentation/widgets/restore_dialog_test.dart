import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/restore_dialog.dart';
import 'package:medora/services/backup_service.dart';

import '../../helpers/pump_app.dart';

final _manifest = BackupManifest(
  version: 1,
  schemaVersion: 13,
  createdAt: DateTime.utc(2026, 3, 4, 16, 5),
  appVersion: '0.1.1+11',
  rowCounts: const {'medications': 2, 'treatments': 1, 'dose_logs': 4},
  photoCount: 3,
);

void main() {
  testWidgets('shows what the backup holds and returns the chosen mode', (
    tester,
  ) async {
    RestoreMode? chosen;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              chosen = await showRestoreDialog(context, _manifest),
          child: const Text('open'),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('7 rows'), findsOneWidget);
    expect(find.textContaining('3 photos'), findsOneWidget);
    expect(find.text('0.1.1+11'), findsOneWidget);
    // Replace is preselected, so its warning is visible from the start.
    expect(find.text('Replace everything'), findsOneWidget);
    expect(
      find.textContaining('Everything on this device is deleted first'),
      findsOneWidget,
    );

    await tester.tap(find.text('Merge with this device'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Everything on this device is deleted first'),
      findsNothing,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(chosen, RestoreMode.merge);
  });

  testWidgets('cancelling returns no mode', (tester) async {
    RestoreMode? chosen;
    var returned = false;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            chosen = await showRestoreDialog(context, _manifest);
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(chosen, isNull);
  });
}
