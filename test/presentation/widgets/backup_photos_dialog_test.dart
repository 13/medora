import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/backup_photos_dialog.dart';
import 'package:medora/services/backup_service.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('counts the photos and includes them by default', (tester) async {
    bool? answer;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showBackupPhotosDialog(
            context,
            photoCount: 4,
            photoBytes: 3 * 1024 * 1024,
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('4 files'), findsOneWidget);
    expect(find.textContaining('3.0 MB'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.textContaining('a lot of photos'), findsNothing);

    await tester.tap(find.text('Back up'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('a payload over the limit starts unticked and warns', (
    tester,
  ) async {
    bool? answer;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await showBackupPhotosDialog(
            context,
            photoCount: 900,
            photoBytes: BackupService.largePhotoBytes + 1,
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(find.textContaining('a lot of photos'), findsOneWidget);
    expect(find.textContaining('150 MB'), findsOneWidget);

    // The user can still insist on the photos.
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back up'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('cancelling backs out of the export', (tester) async {
    bool? answer;
    var returned = false;
    await pumpMedoraApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showBackupPhotosDialog(
              context,
              photoCount: 2,
              photoBytes: 1024,
            );
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

    expect(find.byType(AlertDialog), findsNothing);
    expect(returned, isTrue);
    expect(answer, isNull, reason: 'no answer means no export');
  });
}
